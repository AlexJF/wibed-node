#!/bin/bash

# cd to script's dir
cd ${0%/*}

# Case insensitive regular expression matching
shopt -s nocasematch

# Load resty for easy REST API access
. resty/resty

ID_FILE="state/id"
STATUS_FILE="state/status"
FIRMWAREINFO_FILE="state/firmware"
EXPERIMENTID_FILE="state/experimentId"
COMMANDACK_FILE="state/commandAck"
RESULTACK_FILE="state/resultAck"

RESULTS_DIR="results"

COMMANDS_PIPE="pipes/commands"

SERVER_URL="http://127.0.0.1:5000"

resty $SERVER_URL

# Function: readFile
#
# Reads data from a file or returns some default value
#
# Params:
# - file - The file from which to read the variable.
# - defaultValue - Value to use if file doesn't exist.
#
# Returns:
# - Value read from file or initialized from provided default.
function readFile {
    local file=$1
    local value=$2

    if [ -e $file ] ; then
        readValue=$(< $file)

        if [ "$readValue" ] ; then
            value="$readValue"
        fi
    fi

    echo $value
}

# Function: jsonEscape
#
# Escape characters for JSON output.
# 
# Params:
# - data - Unescaped json data.
#
# Returns:
# - Escaped json data.
function jsonEscape {
    local text=$1

    text=${text//\\/\\\\} # \ 
    text=${text//\//\\\/} # / 
    text=${text//\"/\\\"} # " 
    text=${text//   /\\t} # \t (tab)
    text=${text//$'\n'/\\\n} # \n (newline)
    text=${text//^M/\\\r} # \r (carriage return)
    text=${text//^L/\\\f} # \f (form feed)
    text=${text//^H/\\\b} # \b (backspace)

    echo $text
}


# Function: buildResults
#
# Builds a json list containing information about all non-acknowledged
# results.
#
# Params:
# - resultAck - The current result ack.
#
# Returns:
# - JSON list with information about non-acked results.
function buildResults {
    local resultAck=$1
    local __resultVar=$2

    if [ ! -d "$RESULTS_DIR" ] ; then
        echo "[]"
        return 1
    fi

    local first=1
    local results="["
    local commandIds=$(ls -1 "$RESULTS_DIR")
    for commandId in $commandIds
    do
        cmdResultFolder="$RESULTS_DIR/$commandId"

        if [ $commandId -gt $resultAck ] ; then
            if [[ $first == 0 ]] ; then
                results="$results,"
            fi

            exitCode=$(< "$cmdResultFolder/exitCode")
            stdout=$(< "$cmdResultFolder/stdout")
            stdout=$(jsonEscape "$stdout")
            stderr=$(< "$cmdResultFolder/stderr")
            stderr=$(jsonEscape "$stderr")

            results="$results[$commandId, $exitCode, \"$stdout\", \"$stderr\"]"
            first=0
        fi
    done 
    results="$results]"
    echo $results
}

# Function: parseResopnse
#
# Parses the JSON response string into a set of variables.
#
# Params:
# - json - The json to parse.
function parseResponse {
    local json="$1"
    local response=$(echo "$json" | ./json/JSON.sh -b)

    echo "Response:"
    echo $json
    echo " "
    echo "Parsed response:"
    echo $response

    IFS_BAK=$IFS
    IFS=$'\n'

    responseLineRe='^\[([^]]*)\](.*)$'

    for line in $response; do
        if [[ $line =~ $responseLineRe ]] ; then
            # Remove " from keys and put them in an array
            IFS="," read -ra keys <<< "${BASH_REMATCH[1]//\"/}"

            # Trim value and remove "
            value=$(echo "${BASH_REMATCH[2]//\"/}" | 
                sed -e 's/^[[:space:]]*//g' -e 's/[[:space:]]*$//g')

            if [[ ${keys[0]} == "experiment" ]] ; then
                if [[ ${keys[1]} == "id" ]] ; then
                    experimentId=$value
                elif [[ ${keys[1]} == "overlay" ]] ; then
                    experimentOverlay=$value
                elif [[ ${keys[1]} == "resultAck" ]] ; then
                    experimentResultAck=$value
                elif [[ ${keys[1]} == "action" ]] ; then
                    experimentAction=$value
                elif [[ ${keys[1]} == "commands" ]] ; then
                    if [[ ${keys[3]} == "0" ]] ; then
                        experimentCommandIds[${keys[2]}]="$value"
                    else
                        experimentCommands[${keys[2]}]="$value"
                    fi
                fi
            elif [[ ${keys[0]} == "upgrade" ]] ; then
                if [[ ${keys[1]} == "version" ]] ; then
                    upgradeVersion=$value
                elif [[ ${keys[1]} == "delay" ]] ; then
                    upgradeDelay=$value
                fi
            elif [[ ${keys[0]} == "errors" ]] ; then
                errors[${keys[1]}]="$value"
            fi
        fi
    done 

    # return delimiter to previous value
    IFS=$IFS_BAK
    IFS_BAK=
}

# Function: doFirmwareUpgrade
#
# Start the firmware upgrade process.
#
# Params:
# - version - New firmware version.
# - delay - The delay until the actual installation of the firmware.
function doFirmwareUpgrade {
    local version=$1
    local delay=$2

    status=5
    # TODO: Get overlay from server
    # TODO: Launch upgrade script
}

# Function: doPrepareExperiment
#
# Prepares an experiment by downloading the respective overlay
# and installing it.
#
# Params:
# - experimentId - Id of the experiment.
# - overlayId - The id of the overlay used in the experiment.
function doPrepareExperiment {
    local experimentId=$1
    local overlayId=$2

    if errors=$(curl -o "overlay.tar.gz" "$SERVER_URL/static/overlays/$overlayId" \
            2>&1 >/dev/null) ; then
        status=2
        echo $experimentId > "$EXPERIMENTID_FILE"
        # TODO: Install overlay
        status=3
    else
        # Report error
        echo $errors
    fi
}

# Function: doStartExperiment
#
# Start the experiment.
function doStartExperiment {
    status=4
    # TODO: Call experiment starting script or reboot.

    nohup ./command-executer.sh &
    # Give some time for named pipe to be created
    sleep 1
}

# Function: doFinishExperiment
#
# Finishes an active experiment.
function doFinishExperiment {
    # TODO: Kill experiment process

    echo "-1 exit" > $COMMANDS_PIPE
    rm -r results
    rm -r overlay.tar.gz
    status=1
}

# Function: executeCommands
#
# Sets up the commands provided as argument for execution.
#
# Args:
# cmdIds - An array of command ids.
# cmds - An array of actual commands.
function executeCommands {
    declare -a cmdIds=("${!1}")
    declare -a cmds=("${!2}")
    local lastCommandId=$commandAck

    local numCommands=${#cmdIds[@]}

    for (( i=0; i<numCommands; i++))
    do
        local commandId=${cmdIds[$i]}

        if [[ -z $commandId ]] ; then
            continue
        fi

        # Escape command string
        local command=${cmds[$i]}
        echo "Executing command $commandId \"$command\""
        echo "$commandId $command" > $COMMANDS_PIPE
        lastCommandId=$commandId
    done

    echo $lastCommandId > "$COMMANDACK_FILE"
}

id=$(readFile $ID_FILE 0)
status=$(readFile $STATUS_FILE 0)

request="{\"status\": $status"

case $status in
    0)
        read model version < $FIRMWAREINFO_FILE
        request="$request,
            \"model\": \"$model\",
            \"version\": \"$version\""
        ;;
    [2-4])
        experimentId=$(readFile $EXPERIMENTID_FILE 0)

        if [[ $status == "4" ]] ; then
            commandAck=$(readFile $COMMANDACK_FILE 0)
            resultAck=$(readFile $RESULTACK_FILE 0)
            results=$(buildResults $resultAck)
            request="$request,
                \"commandAck\": $commandAck,
                \"results\": $results"
        fi
        ;;
esac

request="$request}"

echo " "
echo "Request:"
echo $request
echo " "

if response=$(POST /api/wibednode/"$id" "$request" \
        -H "Content-Type: application/json") ; then
    echo "Communication with server successful"
    echo " "
    parseResponse "$response"

    if [[ "${#errors[@]}" -gt 0 ]] ; then
        echo "Error:"
        printf -- '%s\n' "${errors[@]}"
        exit 1
    fi

    # Migration from status 0 to 1 is automatic upon receival of response
    # by server.
    if [[ $status == "0" ]] ; then
        status=1
    fi

    case $status in
        # IDLE
        1)
            if [[ $upgradeVersion ]] ; then
                doFirmwareUpgrade $upgradeVersion $upgradeDelay
            elif [[ $experimentAction == "PREPARE" ]] ; then
                doPrepareExperiment $experimentId $experimentOverlay
            fi
            ;;
        # IN EXPERIMENT
        [234])
            if [[ $experimentAction == "FINISH" ]] ; then
                doFinishExperiment
            fi

            # READY
            if [[ $status == 3 && $experimentAction == "RUN" ]] ; then
                doStartExperiment
            fi

            # RUNNING
            if [[ $status == 4 ]] ; then
                executeCommands experimentCommandIds[@] experimentCommands[@]
                if [[ $experimentResultAck ]] ; then
                    echo $experimentResultAck > $RESULTACK_FILE
                fi
            fi
            ;;

        # UPGRADING
        5)
            ;;
    esac

    # Update status on file
    echo $status > $STATUS_FILE
else
    echo "Communication with server unsuccessful"
fi

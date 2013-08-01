#!/bin/sh

PKGREPO="/home/alex/Projects/wibed/packages/wibed-system/files"

cp wibed-node "$PKGREPO/usr/sbin/"
cp command-executer "$PKGREPO/usr/sbin/"

mkdir -p $PKGREPO/var/wibed/{results,pipes}

sed -ri -e 's/^(RESULTS_DIR=)".*"$/\1"\/var\/wibed\/results"/g' $PKGREPO/usr/sbin/{wibed-node.sh,command-executer.sh}
sed -ri -e 's/^(COMMANDS_PIPE=)".*"$/\1"\/var\/wibed\/pipes\/commands"/g' $PKGREPO/usr/sbin/{wibed-node.sh,command-executer.sh}

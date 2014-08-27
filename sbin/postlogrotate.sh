#!/usr/bin/bash
# vi: sw=4 ts=4 et
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2014, Joyent, Inc.
#

#
# The standard script to be used as the command for '-a CMD' in
# /etc/logadm.conf for rotated SDC logs.  The primary function here is to
# roll the just-rotated "...T%H:%M:%S.log" log file into "...THH:00:00.log" for
# the current hour (rolling backward, the default) *or* for the next hour
# (rolling forward). The latter is to support more-than-once-per-hour rotations
# ending up as one correct hourly log file in Manta. This is needed to not lose
# log data through a "vmadm reprovision" (as is done currently for upgrades).
#
# Usage:
#       lostrotatelog.sh NAME
#
# Environment:
#       SDC_LOG_ROLL_FORWARD=1      If set, then the latest rotated log file
#                                   will be rolled *forward* to the next
#                                   hour. E.g. "...T09:12:34.log" will be
#                                   rolled to "...T10:00:00.log".
#
# where 'NAME' is the base name of the rotated log. Logs are rotated
# to "/var/log/sdc/upload", for example
# "imgapi_8584337e-e54c-4910-86b8-0d5ff9282bbd_2013-10-09T23:00:00.log"
# In this case the 'NAME' is 'imgapi'.
#

if [[ -n "$TRACE" ]]; then
    export PS4='[\D{%FT%TZ}] ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
    set -o xtrace
fi
set -o errexit
set -o pipefail

function fatal() {
    echo "$0: error: $*" >&2
    exit 1
}


#---- mainline

name=$1
[[ -z "$name" ]] && fatal "NAME argument not given"


# Roll this last rotated file fwd (into the top of the next hour)
# or bwd (into the top of this hour). Bwd is the default.
lastlog=$(ls -1t /var/log/sdc/upload/${name}_* | head -1)
if [[ "$SDC_LOG_ROLL_FORWARD" == "1" ]]; then
    # Roll forward.
    base=$(echo $lastlog | cut -d_ -f 1)
    zone=$(echo $lastlog | cut -d_ -f 2)
    logtime=$(echo $lastlog | cut -d_ -f3 | cut -d. -f1)
    # TODO: GZ /usr/bin/date doesn't support -d. Use node? Only if need
    #       support for this code path in GZ.
    DATE=/opt/local/bin/date
    hourfwd=$($DATE -d \@$(( $($DATE -d $logtime "+%s") + 3600 )) "+%Y-%m-%dT%H:00:00")
    cat $lastlog >>${base}_${zone}_${hourfwd}.log
else
    # Roll backward (to the top of this hour).
    base=$(echo $lastlog | cut -d: -f1)   # '/var/log/sdc/upload/$name...T23'
    cat $lastlog >>${base}:00:00.log
fi
rm $lastlog

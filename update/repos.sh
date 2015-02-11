#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2014, Joyent, Inc.
#

###############################################################################
# This script updates all the $REPOS to the latest verion of sdc-scripts.
# It will only update repos that:
#   - Exist at ../[repo]
#   - Don't have current, outstanding changes
#
# It will only update the repos that are out of date, so if there are problems
# with repos, you can fix and safely rerun.
###############################################################################

if [[ -n "$TRACE" ]]; then
    export PS4='[\D{%FT%TZ}] ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
    set -o xtrace
fi
set -o errexit
set -o pipefail


REPOS=(
    binder
    mahi
    moray
    sdc-adminui
    sdc-amon
    sdc-amonredis
    sdc-assets
    sdc-booter
    sdc-cloud-analytics
    sdc-cloudapi
    sdc-cnapi
    sdc-docker
    sdc-fwapi
    sdc-hostvolume
    sdc-imgapi
    sdc-manatee
    sdc-manta
    sdc-nat
    sdc-napi
    sdc-papi
    sdc-portolan
    sdc-rabbitmq
    sdc-redis
    sdc-sapi
    sdc-sdc
    sdc-ufds
    sdc-vmapi
    sdc-workflow
)
PROBLEMS=( )
DEP_LOC="deps/sdc-scripts"

if [ -z "$1" ]; then
    echo "usage: $0 [Jira item for commits]"
    exit 1
fi

JIRA=$1
P=$PWD
if [ $(basename $P) != "sdc-scripts" ]; then
    echo "Script must be run from sdc-scripts directory"
    exit 1
fi
SS_GIT_SHA=$(git rev-parse HEAD)
SS_GIT_SHA_SHORT=$(git rev-parse --short HEAD)

for repo in "${REPOS[@]}"; do
    # Reset to sdc-scripts directory each time
    cd $P

    if [ ! -d "../$repo" ]; then
        PROBLEMS=( "${PROBLEMS[@]}" "$repo" )
        echo "$repo doesn't exist at ../$repo.  Not updating."
        continue
    fi

    echo
    echo "Checking $repo..."
    cd "../$repo"
    git pull --rebase
    if [ $? != 0 ]; then
        PROBLEMS=( "${PROBLEMS[@]}" "$repo" )
        echo "Unable to 'git pull --rebase' $repo. Not updating."
        continue
    fi

    REPO_GIT_SHA=$(git submodule status $DEP_LOC | cut -c 2-41)
    if [ "$SS_GIT_SHA" == "$REPO_GIT_SHA" ]; then
        echo "$repo already has latest sdc-scripts.  Not updating."
        continue
    fi

    echo "Updating $repo..."
    git submodule init $DEP_LOC
    git submodule update $DEP_LOC
    cd $DEP_LOC
    git checkout master
    git pull --rebase origin $(git rev-parse --abbrev-ref HEAD)
    cd -
    git add $DEP_LOC
    git commit -m "$JIRA: Updating to latest sdc-scripts ($SS_GIT_SHA_SHORT)"
    git push origin master
    echo "Done updating $repo."

done

if [ ${#PROBLEMS[*]} != 0 ]; then
    echo ""
    echo "There were problems updating the following repos:"
    echo "${PROBLEMS[@]}"
else
    echo
    echo "All repos up to date."
fi

#Leave you where I found you
cd $P

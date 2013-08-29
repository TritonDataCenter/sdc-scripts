#!/usr/bin/bash
#
# Copyright (c) 2013, Joyent Inc. All rights reserved.
#

function fatal() {
    echo "error: $*" >&2
    exit 1
}

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2014, Joyent, Inc.
-->

These files/scripts are used for configuring sdc zones.  Currently used are:

setup.sh        - called once when first setting up the zone.
configure.sh    - called on every zone boot.
lib/util.sh     - contains common functions for setting up SDC zones.
etc/root.bashrc - will be loaded as /root/.bashrc in SDC zones.

The files in the sdc-scripts.git repo are copied in first and then the files
in the zone's <repo>.git/boot directory are copied over.  This way the
sdc-scripts.git files act as defaults but the zone can (and must in the case
of setup.sh and configure.sh) use its own files.

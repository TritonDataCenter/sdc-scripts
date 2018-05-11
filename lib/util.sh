#!/usr/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright 2016 Joyent, Inc.
#

#
# Usage in a Triton core zone "boot/setup.sh" file:
#
#   role=myapi
#   ...
#
#   source /opt/smartdc/boot/lib/util.sh
#   CONFIG_AGENT_LOCAL_MANIFESTS_DIRS=/opt/smartdc/$role
#   sdc_common_setup
#   ...
#
#   # Typically some log rotation setup. E.g.:
#   echo "Adding log rotation"
#   sdc_log_rotation_add amon-agent /var/svc/log/*amon-agent*.log 1g
#   sdc_log_rotation_add config-agent /var/svc/log/*config-agent*.log 1g
#   sdc_log_rotation_add registrar /var/svc/log/*registrar*.log 1g
#   sdc_log_rotation_add $role /var/svc/log/*$role*.log 1g
#   sdc_log_rotation_setup_end
#
#   # All done, run boilerplate end-of-setup
#   sdc_setup_complete
#

#
# NOTE: This script is a library sourced by various other Triton software
# living in other consolidations.  The functions provided in this script must
# operate correctly under any combination of the shell options "errexit",
# "pipefail", and "nounset".
#

function fatal
{
    printf '%s: ERROR: %s\n' "$(basename $0)" "$*" >&2
    exit 1
}

function warn
{
    printf '%s: WARNING: %s\n' "$(basename $0)" "$*" >&2
}

function _sdc_lib_util_deprecated_function
{
    warn "The function \"$1\" (in sdc-scripts) is deprecated."
}

#
# Fetch a value from the metadata agent.  This function checks to make sure the
# fetch was successful, and that the value returned is not the empty string.
# All failures will exit the program with an appropriate message and a non-zero
# status.
#
# NOTE: If running this function to capture the output, bash will run
# the function in a subshell so the "fatal" invocations will NOT cause
# the exit of the process.  The caller MUST check the return code; e.g.
#
#   if ! value=$(_sdc_mdata_get sdc:nics); then
#       fatal 'failed to get NIC data'
#   fi
#
function _sdc_mdata_get
{
    local md_key=${1:-}
    local md_value=

    if [[ -z $md_key ]]; then
        fatal "${FUNCNAME[0]} requires a metadata key"
    fi
    printf 'Loading metadata for key "%s".\n' "$md_key" >&2

    if ! md_value=$(/usr/sbin/mdata-get "$md_key"); then
        fatal "could not load \"$md_key\" from metadata agent"
    fi

    if [[ -z $md_value ]]; then
        fatal "empty metadata value for key \"$md_key\""
    fi

    printf '%s' "$md_value"
    return 0
}

#
# Run curl(1) with options that attempt to prevent it swallowing errors, or
# hanging forever in the event of pathological server or network behaviour.
# Note that "--max-time" is a hard cap on the entire request duration, so it
# should not be made too short.
#
function _sdc_curl
{
    curl -sSf --connect-timeout 45 --max-time 120 "$@"
}

function _sdc_import_smf_manifest
{
    local fmri=${1:-}

    if [[ -z $fmri ]]; then
        fatal "${FUNCNAME[0]} requires an FMRI"
    fi

    printf 'Importing smf(5) manifest "%s".\n' "$fmri" >&2
    if ! /usr/sbin/svccfg import "$fmri"; then
        fatal "could not import smf(5) manifest \"$fmri\""
    fi
}

function _sdc_enable_smf_service
{
    local fmri=${1:-}
    local waitflag=${2:-}
    local flags=()

    if [[ -z $fmri ]]; then
        fatal "${FUNCNAME[0]} requires an FMRI"
    fi

    if [[ $waitflag == "wait" ]]; then
        flags+=( '-s' )
    elif [[ -n $waitflag ]]; then
        fatal "_sdc_enable_smf_service: invalid waitflag: $waitflag"
    fi

    printf 'Enabling smf(5) service "%s".\n' "$1" >&2
    if ! /usr/sbin/svcadm enable "${flags[@]}" "$1"; then
        fatal "could not enable smf(5) service \"$1\""
    fi
}

function _sdc_restart_smf_service
{
    local fmri=${1:-}
    local waitflag=${2:-}
    local flags=()

    if [[ -z $fmri ]]; then
        fatal "${FUNCNAME[0]} requires an FMRI"
    fi

    if [[ $waitflag == "wait" ]]; then
        flags+=( '-s' )
    elif [[ -n $waitflag ]]; then
        fatal "${FUNCNAME[0]}: invalid waitflag: $waitflag"
    fi

    printf 'Disabling smf(5) service "%s" as part of restart.\n' "$fmri" >&2
    if ! /usr/sbin/svcadm disable "${flags[@]}" "$fmri"; then
        fatal "could not disable smf(5) service \"$fmri\" as part of restart"
    fi
    printf 'Enabling smf(5) service "%s" as part of restart.\n' "$fmri" >&2
    if ! /usr/sbin/svcadm enable "${flags[@]}" "$fmri"; then
        fatal "could not enable smf(5) service \"$fmri\" as part of restart"
    fi
}

function _sdc_load_variables
{
    if ! ZONE_ROLE=$(_sdc_mdata_get sdc:tags.smartdc_role); then
        fatal 'could not get zone role'
    fi

    export ZONE_ROLE
}

function _sdc_create_dcinfo
{
    local dc_name

    if ! dc_name=$(_sdc_mdata_get sdc:datacenter_name); then
        fatal 'could not get data center name'
    fi

    #
    # Setup "/.dcinfo": info about the datacenter in which this zone runs (used
    # for a more helpful PS1 prompt).
    #
    if ! printf 'SDC_DATACENTER_NAME="%s"\n' "$dc_name" > /.dcinfo; then
        fatal "could not create /.dcinfo file"
    fi
}

function _sdc_install_bashrc
{
    if [[ ! -f /opt/smartdc/boot/etc/root.bashrc ]]; then
        return 0
    fi

    /usr/bin/rm -f /root/.bashrc
    if ! /usr/bin/cp /opt/smartdc/boot/etc/root.bashrc /root/.bashrc; then
        fatal 'could not install "/root/.bashrc"'
    fi
}

function _sdc_setup_amon_agent
{
    if [[ -f /var/svc/setup_complete ]]; then
        return 0
    fi

    if [[ ! -d /opt/amon-agent ]]; then
        return 0
    fi

    if ! (cd /opt/amon-agent && ./pkg/postinstall.sh); then
        fatal 'could not install amon-agent'
    fi

    /usr/bin/rm -f /var/svc/amon-agent.tgz
}

function setup_config_agent
{
    local dirlist=${CONFIG_AGENT_LOCAL_MANIFESTS_DIRS:-}
    local prefix=/opt/smartdc/config-agent
    local config_file=$prefix/etc/config.json
    local node=$prefix/build/node/bin/node
    local script=/opt/smartdc/boot/lib/setup_config_agent.js
    local sapi_url

    if [[ ! -d $prefix ]]; then
        return 0
    fi

    #
    # Note that the temporary file is not in "/tmp", but rather within the
    # target prefix directory.  This makes it more likely that the resultant
    # mv(1) operation will be an atomic rename(2).
    #
    local target="$prefix/smf/manifests/config-agent.xml"
    local tmpfile="$prefix/.new.config-agent.xml"

    printf 'Setting up config-agent.\n' >&2
    if ! sapi_url=$(_sdc_mdata_get sapi-url); then
        fatal 'could not get SAPI URL'
    fi

    #
    # Ensure that the @@PREFIX@@ token in the smf(5) manifest is correctly
    # replaced with the location at which config-agent is installed.
    #
    /usr/bin/rm -f "$tmpfile"
    if ! /usr/bin/sed -e "s#@@PREFIX@@#$prefix#g" "$target" > "$tmpfile"; then
        fatal "could not perform substitutions on \"$target\""
    fi
    if ! /usr/bin/mv "$tmpfile" "$target"; then
        fatal "could not move edited file \"$tmpfile\" into place"
    fi

    #
    # Callers can pass a list of directories that config-agent should search
    # for SAPI manifests shipped within the image itself.  We must construct a
    # configuration file that includes these directories, as well as a variety
    # of default settings.
    #
    if ! /usr/bin/mkdir -p "$prefix/etc"; then
        fatal 'could not create config-agent config dir'
    fi
    if ! "$node" "$script" 'init' "$config_file" "$sapi_url" "$dirlist"; then
        fatal 'could not generate initial config-agent config JSON'
    fi
}

#
# Add a directory in which to search for local config manifests
#
function config_agent_add_manifest_dir
{
    local dir=${1:-}
    local prefix=/opt/smartdc/config-agent
    local config_file=$prefix/etc/config.json
    local node=$prefix/build/node/bin/node
    local script=/opt/smartdc/boot/lib/setup_config_agent.js

    if [[ -z $dir ]]; then
        fatal "${FUNCNAME[0]} requires a directory name"
    fi

    if [[ ! -f $config_file ]]; then
        fatal 'config-agent configuration file does not yet exist'
    fi

    if ! "$node" "$script" 'add_manifest_dir' "$config_file" "$dir"; then
        fatal 'could not add directory to config-agent configuration file'
    fi
}

#
# SAPI-224: This was dropped, however we keep a stub here to not break
# the call to 'upload_values' in the SAPI zone from headnode.sh in the
# GZ in case we get a mix of old-headnode.sh + new-sapi-image.
#
# After some reasonable period, this stub could be dropped.
#
function upload_values
{
    _sdc_lib_util_deprecated_function upload_values
}

#
# Configuration handling: the following three functions import the config-agent,
# upload the zone's IP addresses into its metadata, and download the zone
# metadata into a temporary file.  The zone's setup script can inspect this
# temporary file for information about the zone's metadata.
#
# Any other scripts or services which require ongoing access to SAPI metadata
# (apart from files managed by the config-agent) should poll the /configs
# SAPI endpoint.
#

#
# Download this zone's SAPI metadata and save it in a local file.
#
function download_metadata
{
    local sdc_nics
    local admin_mac
    local url
    local i

    if ! sdc_nics=$(_sdc_mdata_get sdc:nics); then
        fatal 'could not get NIC information'
    fi

    if ! admin_mac=$(json -c 'this.nic_tag === "admin"' 0.mac \
      <<< "$sdc_nics"); then
        fatal 'could not parse sdc:nics as JSON'
    fi
    if [[ -z $admin_mac ]]; then
        warn "skipping download of SAPI metadata: don't have admin NIC"
        return 0
    fi

    export METADATA=/var/tmp/metadata.json
    printf 'Downloading SAPI metadata to: %s\n' "${METADATA}" >&2

    if ! url="$(_sdc_mdata_get sapi-url)/configs/$(zonename)"; then
        fatal 'could not get SAPI URL or zone name'
    fi
    printf 'Using SAPI URL: %s\n' "$url" >&2

    i=0
    while (( i++ < 30 )); do
        #
        # Make sure the temporary files do not exist:
        #
        /usr/bin/rm -f "$METADATA.raw"
        /usr/bin/rm -f "$METADATA.extracted"

        #
        # Download SAPI configuration for this instance:
        #
        if ! _sdc_curl -o "$METADATA.raw" "$url"; then
            warn "could not download SAPI metadata (retrying)"
            sleep 2
            continue
        fi

        #
        # Extract the metadata object from the SAPI configuration:
        #
        if ! json -f "$METADATA.raw" metadata > "$METADATA.extracted"; then
            warn "could not parse SAPI metadata (retrying)"
            sleep 2
            continue
        fi

        #
        # Make sure we did not write an empty file:
        #
        if [[ ! -s "$METADATA.extracted" ]]; then
            fatal "metadata file was empty"
        fi

        #
        # Move the metadata file into place:
        #
        if ! /usr/bin/mv "$METADATA.extracted" "$METADATA"; then
            fatal "could not move metadata file into place"
        fi

        /usr/bin/rm -f "$METADATA.raw"
        return 0
    done

    fatal "failed to download SAPI configuration (too many retries)"
}

function write_initial_config
{
    local prefix=/opt/smartdc/config-agent
    local node=$prefix/build/node/bin/node

    if [[ ! -d $prefix ]]; then
        return 0
    fi

    printf 'Writing initial SAPI manifests.\n' >&2

    #
    # Trigger config-agent to synchronously write an initial copy of any
    # service configuration files.
    #
    if ! "$node" "$prefix/agent.js" -s; then
        fatal 'synchronous config-agent run failed'
    fi

    _sdc_import_smf_manifest "$prefix/smf/manifests/config-agent.xml"
    _sdc_enable_smf_service 'svc:/smartdc/application/config-agent:default'
}

#
# SAPI-255: This was dropped, however we keep a stub here to not break
# the call to 'sapi_adopt' in the SAPI zone from headnode.sh in the
# GZ in case we get a mix of old-headnode.sh + new-sapi-image.
#
# After some reasonable period, this stub could be dropped.
#
function sapi_adopt
{
    _sdc_lib_util_deprecated_function sapi_adopt
}

function registrar_setup
{
    if [[ ! -d /opt/smartdc/registrar ]]; then
        return 0
    fi

    local manifest=/opt/smartdc/registrar/smf/manifests/registrar.xml
    local config=/opt/smartdc/registrar/etc/config.json

    if [[ ! -f $manifest ]]; then
        return 0
    fi

    if [[ ! -f $config ]]; then
        fatal "no registrar config for ${ZONE_ROLE}"
    fi

    #
    # NOTE: We do not block waiting for registrar to start as it depends on the
    # transient "svc:/smartdc/mdata:execute" service.  This function is
    # executed as part of the start method for that service, so if we block
    # here we will essentially deadlock with ourselves.
    #
    _sdc_import_smf_manifest "$manifest"
    _sdc_enable_smf_service 'svc:/manta/application/registrar:default'
}

#
# Triton service zones are based on the "joyent-minimal" brand, in which the
# cron smf(5) service is not enabled by default.  We want to enable it so that
# logadm(1M) is invoked periodically for log rotation.
#
function _sdc_enable_cron
{
    _sdc_import_smf_manifest '/lib/svc/manifest/system/cron.xml'
    _sdc_enable_smf_service 'svc:/system/cron:default' wait
}

function _sdc_log_rotation_setup
{
    local dir

    #
    # Create Triton service log upload directories and set appropriate
    # permissions.
    #
    for dir in /var/log/sdc /var/log/sdc/upload; do
        if ! /usr/bin/mkdir -p "$dir"; then
            fatal "could not create log directory \"$dir\""
        fi

        if ! /usr/bin/chown root:sys "$dir"; then
            fatal "could not set permissions on log directory \"$dir\""
        fi
    done

    #
    # Ensure that logadm sends a SIGHUP to "rsyslogd" when rotating log files.
    #
    if ! /usr/sbin/logadm -r /var/adm/messages; then
        fatal "could not clear logadm(1M) rules for /var/adm/messages"
    fi
    if ! /usr/sbin/logadm -w /var/adm/messages -C 4 -a \
      'kill -HUP `cat /var/run/rsyslogd.pid`'; then
        fatal "could not add logadm(1M) rule for /var/adm/messages"
    fi
}

#
# Add an entry to /etc/logadm.conf for hourly log rotation of important Triton
# logs.
#
# Usage:
#   sdc_log_rotation_add <name> <file-pattern> [<size-limit>]
#
# "<name>" is a short string (spaces and '_' are NOT allowed) name for
# this log set. "<file-pattern>" is the path to the file (or a file pattern)
# to rotate. If a pattern it should resolve to a single file -- i.e. allowing
# a pattern is just for convenience. "<size-limit>" is an optional upper size
# limit on all the rotated logs. It corresponds to the '-S size' argument in
# logadm(1M).
#
# Examples:
#   sdc_log_rotation_add amon-agent /var/svc/log/*amon-agent*.log 1g
#   sdc_log_rotation_add imgapi /var/svc/log/*imgapi*.log 1g
#
function sdc_log_rotation_add
{
    local name=${1:-}
    local pattern=${2:-}
    local size=${3:-}
    local flags=()
    local unsafe_regex='[_ ]'

    if [[ -z $name ]]; then
        fatal "${FUNCNAME[0]} requires at least 1 argument"
    fi

    if [[ $name =~ $unsafe_regex ]]; then
        fatal "${FUNCNAME[0]}: 'name' cannot include spaces or " \
          "underscores: '$name'"
    fi

    if [[ -n $size ]]; then
        flags+=( '-S' )
        flags+=( $size )
    fi

    if ! /usr/sbin/logadm -w "$name" "${flags[@]}" -C 168 -c -p 1h \
      -t "/var/log/sdc/upload/${name}_\$nodename_%FT%H:%M:%S.log" \
      -a "/opt/smartdc/boot/sbin/postlogrotate.sh $name" "$pattern"; then
        fatal "could not add logadm(1M) rule for service log \"$name\""
    fi
}

function sdc_log_rotation_setup_end
{
    local crontab
    local logadm_regex='logadm'

    #
    # Move the smf_logs entry to run last (after the entries we just added) so
    # that the default '-C 3' doesn't defeat our attempts to save out.
    #
    if ! /usr/sbin/logadm -r smf_logs; then
        fatal "could not clear logadm(1M) rules for smf(5) log files"
    fi
    if ! /usr/sbin/logadm -w smf_logs -C 3 -c -s 1m '/var/svc/log/*.log'; then
        fatal "could not add logadm(1M) rule for smf(5) log files"
    fi

    #
    # Origin images after smartos@1.6.3 added these logadm.conf entries:
    #       /var/log/*.log -C 2 -c -s 5m
    #       /var/log/*.debug -C 2 -c -s 5m
    #
    # Move the "*.log" entry to the end to not conflict with possible
    # Triton rotation of "/var/log/*.log". However we *do* want to keep it
    # as a useful catch-all for build-up of other log files there.
    #
    # Drop the "*.debug" entry. It is a crufty entry from old vmadm logs.
    #
    if egrep '^/var/log/\*\.log' /etc/logadm.conf >/dev/null; then
        if ! /usr/sbin/logadm -r '/var/log/*.log'; then
            fatal 'could not clear logadm(1M) rule for "/var/log/*.log" files'
        fi
    fi
    if ! /usr/sbin/logadm -w '/var/svc/log/*.log' -C 2 -c -s 5m;  then
        fatal 'could not add logadm(1M) rule for "/var/log/*.log" files'
    fi
    if egrep '^/var/log/\*\.debug' /etc/logadm.conf >/dev/null; then
        if ! /usr/sbin/logadm -r '/var/log/*.debug'; then
            fatal 'could not clear logadm(1M) rule for "/var/log/*.debug" files'
        fi
    fi

    #
    # Scrub existing logadm(1M) invocations from the root crontab:
    #
    if ! crontab=$(/usr/bin/crontab -l); then
        fatal "could not read root crontab"
    fi
    if ! crontab=$(/usr/bin/sed -e '/# Rotate system logs/d' \
      -e '/\/usr\/sbin\/logadm$/d' <<< "$crontab"); then
        fatal "could not remove logadm(1M) entries from crontab"
    fi
    if [[ $crontab =~ $logadm_regex ]]; then
        fatal "not all 'logadm' references removed from crontab"
    fi

    #
    # Add new hourly logadm(1M) entry to the crontab and install it:
    #
    crontab=$(printf '%s\n\n%s\n' "$crontab"
        '0 * * * * /usr/sbin/logadm -v >> /var/log/logadm.log 2>&1')
    if ! /usr/bin/crontab <<< "$crontab"; then
        fatal "could not install root crontab"
    fi
}

function _sdc_rbac_install_shard
{
    local dbname=${1:-}
    local shard=${2:-}
    local dbdir
    local srcdir

    if [[ -z $dbname || -z $shard ]]; then
        fatal "${FUNCNAME[0]} requires a database name and a shard name"
    fi

    case "$dbname" in
    exec_attr|prof_attr)
        dbdir="/etc/security/$dbname.d"
        srcdir="/opt/smartdc/boot$dbdir"
        ;;
    *)
        fatal "unknown rbac(5) database name: $dbname"
        ;;
    esac

    if ! /usr/bin/mkdir -p "$dbdir"; then
        fatal "could not create rbac(5) database shard directory \"$dbdir\""
    fi

    /usr/bin/rm -f "$dbdir/$shard"
    if ! /usr/bin/cp "$srcdir/$shard" "$dbdir/$shard"; then
        fatal "could not install rbac(5) shard \"$shard\" from \"$srcdir\""
    fi

    #
    # The "svc:/system/rbac:default" service is a transient service that merges
    # any updated shard files into the primary file for each rbac(5) database.
    # When installing a new shard file, we restart it synchronously to ensure
    # the primary database file is up to date.
    #
    _sdc_restart_smf_service 'svc:/system/rbac:default' wait
}

#
# Sets up RBAC profiles for access to zone metadata, and imports the pfexec SMF
# service.
#
function _sdc_mdata_rbac_setup
{
    local pfexecd_xml='/lib/svc/manifest/system/pfexecd.xml'
    local rbac_xml='/lib/svc/manifest/system/rbac.xml'

    #
    # On old platforms (i.e. before ~201506), some smf(5) manifests were not
    # available to zones using the "joyent-minimal" brand.  In order to support
    # those older platforms we ship a copy of the manifests we need, to be
    # imported if they are not made available by the platform image.
    #
    if [[ ! -e $pfexecd_xml ]]; then
        warn "platform does not expose pfexecd.xml; backfilling..."
        pfexecd_xml="/opt/smartdc/boot/smf/manifests/pfexecd.xml"
    fi
    if [[ ! -e $rbac_xml ]]; then
        warn "platform does not expose rbac.xml; backfilling..."
        rbac_xml="/opt/smartdc/boot/smf/manifests/rbac.xml"
    fi

    _sdc_import_smf_manifest "$pfexecd_xml"
    _sdc_import_smf_manifest "$rbac_xml"
    _sdc_enable_smf_service 'svc:/system/pfexec:default' wait
    _sdc_enable_smf_service 'svc:/system/rbac:default' wait

    _sdc_rbac_install_shard 'prof_attr' 'mdata'
    _sdc_rbac_install_shard 'exec_attr' 'mdata'
}

#
# Main entry point for the "setup.sh" script shipped in a Triton core zone
# image.  A full usage example appears in the block comment at the top of
# this file.
#
# Optional input environment variables:
#
#   CONFIG_AGENT_LOCAL_MANIFESTS_DIRS
#
#     A space-separated list of fully-qualified directory paths where
#     config-agent should search for SAPI configuration manifests.
#
#   SAPI_PROTO_MODE
#
#     This variable can be set to "true" in the context of an instance
#     of the "sapi" service when SAPI is to operate in the "proto"
#     mode; i.e.  without being fully initialised and available for
#     use.
#
#     If set to "true", no attempt will be made to configure
#     "config-agent" or "registrar" in a "sapi" zone -- these steps
#     depend on SAPI, which, by construction, is not currently
#     available.  If unset, or set to any other value, or this is not
#     a "sapi" zone, there will be no effect.
#
function sdc_common_setup
{
    _sdc_load_variables

    printf 'Performing setup of "%s" zone...\n' "${ZONE_ROLE}" >&2

    _sdc_create_dcinfo
    _sdc_install_bashrc
    _sdc_setup_amon_agent
    _sdc_log_rotation_setup
    _sdc_mdata_rbac_setup

    if [[ -f /var/svc/setup_complete ]]; then
        echo "Skip config-agent/registrar setup: zone already setup" >&2
    elif [[ ${ZONE_ROLE} == "assets" ]]; then
        echo "Skip config-agent/registrar setup: assets zone" >&2
    elif [[ ${ZONE_ROLE} == "sapi" && "${SAPI_PROTO_MODE}" == "true" ]]; then
        echo "Skip config-agent/registrar setup: sapi zone in proto mode" >&2
    else
        echo "Setup config-agent/registrar" >&2
        setup_config_agent
        download_metadata
        write_initial_config
        registrar_setup
    fi

    _sdc_enable_cron
}

#
# Create the setup_complete file and prepare to copy the log. This should be
# called as the last thing before setup exits.
#
function sdc_setup_complete
{
    touch /var/svc/setup_complete
    echo "setup done" >&2

    # we copy the log in the background in 5 seconds so that we get the exit
    # in the log.
    (sleep 5; cp /var/svc/setup.log /var/svc/setup_init.log) &
}

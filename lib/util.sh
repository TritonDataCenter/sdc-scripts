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
# operate safely when the shell options "errexit", or "pipefail", or both, or
# neither, are active.
#

function fatal()
{
    printf '%s: ERROR: %s\n' "$(basename $0)" "$*" >&2
    exit 1
}

function warn()
{
    printf '%s: WARNING: %s\n' "$(basename $0)" "$*" >&2
}

function _sdc_lib_util_deprecated_function()
{
    warn "The function \"$1\" (in sdc-scripts) is deprecated."
}

#
# Fetch a value from the metadata agent.  This function checks to make sure the
# fetch was successful, and that the value returned is not the empty string.
# All failures will exit the program with an appropriate message and a non-zero
# status.
#
function _sdc_mdata_get()
{
    local md_key=${1:-}
    local md_value=

    if [[ -z $md_key ]]; then
        fatal '_sdc_mdata_get requires a metadata key'
    fi
    printf 'Loading metadata for key "%s".\n' "$md_key"

    if ! md_value=$(/usr/sbin/mdata-get "$md_key"); then
        fatal "Could not load \"$md_key\" from metadata agent"
    fi

    if [[ -z $md_value ]]; then
        fatal "Empty metadata value for key \"$md_key\""
    fi

    printf '%s' "$md_value"
    return 0
}

function _sdc_import_smf_manifest()
{
    printf 'Importing smf(5) manifest "%s".\n' "$1"
    if ! /usr/sbin/svccfg import "$1"; then
        fatal "Could not import smf(5) manifest \"$1\""
    fi
}

function _sdc_enable_smf_service()
{
    printf 'Enabling smf(5) service "%s".\n' "$1"
    if ! /usr/sbin/svcadm enable -s "$1"; then
        fatal "Could not enable smf(5) service \"$1\""
    fi
}

function _sdc_restart_smf_service()
{
    printf 'Disabling smf(5) service "%s" as part of restart.\n' "$1"
    if ! /usr/sbin/svcadm disable -s "$1"; then
        fatal "Could not disable smf(5) service \"$1\" as part of restart"
    fi
    printf 'Enabling smf(5) service "%s" as part of restart.\n' "$1"
    if ! /usr/sbin/svcadm enable -s "$1"; then
        fatal "Could not enable smf(5) service \"$1\" as part of restart"
    fi
}

function _sdc_load_variables()
{
    export ZONE_ROLE=$(_sdc_mdata_get sdc:tags.smartdc_role)
}

function _sdc_create_dcinfo()
{
    local dc_name

    dc_name=$(_sdc_mdata_get sdc:datacenter_name)

    #
    # Setup "/.dcinfo": info about the datacenter in which this zone runs (used
    # for a more helpful PS1 prompt).
    #
    printf 'SDC_DATACENTER_NAME="%s"\n' "$dc_name" > /.dcinfo
}

function _sdc_install_bashrc()
{
    if [[ ! -f /opt/smartdc/boot/etc/root.bashrc ]]; then
        return 0
    fi

    /usr/bin/rm -f /root/.bashrc
    if ! /usr/bin/cp /opt/smartdc/boot/etc/root.bashrc /root/.bashrc; then
        fatal 'Could not install "/root/.bashrc"'
    fi
}

function _sdc_setup_amon_agent()
{
    if [[ -f /var/svc/setup_complete ]]; then
        return 0
    fi

    if [[ ! -d /opt/amon-agent ]]; then
        return 0
    fi

    if ! (cd /opt/amon-agent && ./pkg/postinstall.sh); then
        fatal 'Could not install amon-agent'
    fi

    /usr/bin/rm -f /var/svc/amon-agent.tgz
}

function setup_config_agent()
{
    local prefix=/opt/smartdc/config-agent
    local config_file=$prefix/etc/config.json
    local node=$prefix/build/node/bin/node
    local sapi_url
    local config

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

    printf 'Setting up config-agent.\n'
    sapi_url=$(_sdc_mdata_get sapi-url)

    #
    # Ensure that the @@PREFIX@@ token in the smf(5) manifest is correctly
    # replaced with the location at which config-agent is installed.
    #
    /usr/bin/rm -f "$tmpfile"
    if ! /usr/bin/sed -e "s#@@PREFIX@@#$prefix#g" "$target" > "$tmpfile"; then
        fatal "Could not perform substitutions on \"$target\""
    fi
    if ! /usr/bin/mv "$tmpfile" "$target"; then
        fatal "Could not move edited file \"$tmpfile\" into place"
    fi

    #
    # Callers can pass a list of directories that config-agent should search
    # for SAPI manifests shipped within the image itself.  We must construct a
    # configuration file that includes these directories, as well as a variety
    # of default settings.
    #
    if ! /usr/bin/mkdir -p "$prefix/etc"; then
        fatal 'Could not create config-agent config dir'
    fi
    if ! "$node" -e '
        var mod_fs = require("fs");

        var fromenv = process.env.CONFIG_AGENT_LOCAL_MANIFESTS_DIRS;
        var dirs = [];

        if (fromenv) {
            var t = fromenv.split(/[ \t]+/);

            for (var i = 0; i < t.length; i++) {
                var dir = t[i].trim();

                if (dir && dirs.indexOf(dir) === -1) {
                    dirs.push(dir);
                }
            }
        }

        mod_fs.writeFileSync(process.argv[1], JSON.stringify({
            logLevel: "info",
            pollInterval: 60 * 1000,
            sapi: {
                url: process.argv[2]
            },
            localManifestDirs: dirs
        }));

    ' "$config_file" "$sapi_url"; then
        fatal 'Could not generate initial config-agent config JSON'
    fi
}

# Add a directory in which to search for local config manifests
function config_agent_add_manifest_dir
{
    local prefix=/opt/smartdc/config-agent
    local config_file=$prefix/etc/config.json
    local node=$prefix/build/node/bin/node
    local dir=${1:-}

    if [[ -z $dir ]]; then
        fatal "config_agent_add_manifest_dir requires a directory name"
    fi

    if [[ ! -f $config_file ]]; then
        fatal 'config-agent configuration file does not yet exist'
    fi

    if ! "$node" -e '
        var mod_fs = require("fs");

        var obj = JSON.parse(mod_fs.readFileSync(process.argv[1]));

        if (!obj.localManifestDirs) {
            obj.localManifestDirs = [];
        }
        obj.localManifestDirs.push(process.argv[2]);

        mod_fs.writeFileSync(process.argv[1], JSON.stringify(obj));

    ' "$config_file" "$dir"; then
        fatal 'Could not add directory to config-agent configuration file'
    fi
}

# SAPI-224: This was dropped, however we keep a stub here to not break
# the call to 'upload_values' in the SAPI zone from headnode.sh in the
# GZ in case we get a mix of old-headnode.sh + new-sapi-image.
#
# After some reasonable period, this stub could be dropped.
function upload_values()
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
function download_metadata()
{
    local sdc_nics
    local admin_mac
    local url
    local i

    sdc_nics=$(_sdc_mdata_get sdc:nics)

    if ! admin_mac=$(json -c 'this.nic_tag === "admin"' 0.mac \
      <<< "$sdc_nics"); then
        fatal 'Could not parse sdc:nics as JSON'
    fi
    if [[ -z $admin_mac ]]; then
        warn "Skipping download of SAPI metadata: don't have admin NIC"
        return 0
    fi

    export METADATA=/var/tmp/metadata.json
    printf 'Downloading SAPI metadata to: %s\n' "${METADATA}" >&2

    url="$(_sdc_mdata_get sapi-url)/configs/$(zonename)"
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
        if ! curl -sSf -o "$METADATA.raw" "$url"; then
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

function write_initial_config()
{
    local prefix=/opt/smartdc/config-agent
    local node=$prefix/build/node/bin/node

    if [[ ! -d $prefix ]]; then
        return 0
    fi

    printf 'Writing initial SAPI manifests.\n'

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

# SAPI-255: This was dropped, however we keep a stub here to not break
# the call to 'sapi_adopt' in the SAPI zone from headnode.sh in the
# GZ in case we get a mix of old-headnode.sh + new-sapi-image.
#
# After some reasonable period, this stub could be dropped.
function sapi_adopt()
{
    _sdc_lib_util_deprecated_function sapi_adopt
}

function registrar_setup()
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
        fatal "No registrar config for ${ZONE_ROLE}"
    fi

    _sdc_import_smf_manifest "$manifest"
    _sdc_enable_smf_service 'svc:/manta/application/registrar:default'
}

#
# Triton service zones are based on the "joyent-minimal" brand, in which the
# cron smf(5) service is not enabled by default.  We want to enable it so that
# logadm(1M) is invoked periodically for log rotation.
#
function _sdc_enable_cron()
{
    _sdc_import_smf_manifest '/lib/svc/manifest/system/cron.xml'
    _sdc_enable_smf_service 'svc:/system/cron:default'
}

function _sdc_log_rotation_setup()
{
    local dir

    #
    # Create Triton service log upload directories and set appropriate
    # permissions.
    #
    for dir in /var/log/sdc /var/log/sdc/upload; do
        if ! /usr/bin/mkdir -p "$dir"; then
            fatal "Could not create log directory \"$dir\""
        fi

        if ! /usr/bin/chown root:sys "$dir"; then
            fatal "Could not set permissions on log directory \"$dir\""
        fi
    done

    #
    # Ensure that logadm sends a SIGHUP to "rsyslogd" when rotating log files.
    #
    if ! /usr/sbin/logadm -r /var/adm/messages; then
        fatal "Could not clear logadm(1M) rules for /var/adm/messages"
    fi
    if ! /usr/sbin/logadm -w /var/adm/messages -C 4 -a \
      'kill -HUP `cat /var/run/rsyslogd.pid`'; then
        fatal "Could not add logadm(1M) rule for /var/adm/messages"
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
function sdc_log_rotation_add()
{
    local name=${1:-}
    local pattern=${2:-}
    local size=${3:-}
    local extra_opts=

    if [[ -z $name ]]; then
        fatal "sdc_log_rotation_add requires at least 1 argument"
    fi

    if /usr/bin/grep '[_ ]' <<< "$name" >/dev/null; then
        fatal "sdc_log_rotation_add: 'name' cannot include spaces or " \
          "underscores: '$name'"
    fi

    if [[ -n "$size" ]]; then
        extra_opts="$extra_opts -S $size"
    fi

    if ! /usr/sbin/logadm -w "$name" $extra_opts -C 168 -c -p 1h \
      -t "/var/log/sdc/upload/${name}_\$nodename_%FT%H:%M:%S.log" \
      -a "/opt/smartdc/boot/sbin/postlogrotate.sh ${name}" "$pattern"; then
        fatal "could not add logadm(1M) rule for service log \"$name\""
    fi
}

function sdc_log_rotation_setup_end()
{
    local crontab

    #
    # Move the smf_logs entry to run last (after the entries we just added) so
    # that the default '-C 3' doesn't defeat our attempts to save out.
    #
    if ! /usr/sbin/logadm -r smf_logs; then
        fatal "Could not clear logadm(1M) rules for smf(5) log files"
    fi
    if ! /usr/sbin/logadm -w smf_logs -C 3 -c -s 1m '/var/svc/log/*.log'; then
        fatal "Could not add logadm(1M) rule for smf(5) log files"
    fi

    #
    # Scrub existing logadm(1M) invocations from the root crontab:
    #
    if ! crontab=$(/usr/bin/crontab -l); then
        fatal "Could not read root crontab"
    fi
    if ! crontab=$(/usr/bin/sed -e '/# Rotate system logs/d' \
      -e '/\/usr\/sbin\/logadm$/d' <<< "$crontab"); then
        fatal "Could not remove logadm(1M) entries from crontab"
    fi
    if grep logadm <<< "$crontab" >/dev/null; then
        fatal "Not all 'logadm' references removed from crontab"
    fi

    #
    # Add new hourly logadm(1M) entry to the crontab and install it:
    #
    crontab=$(printf '%s\n\n%s\n' "$crontab" "0 * * * * /usr/sbin/logadm")
    if ! crontab <<< "$crontab"; then
        fatal "Could not install root crontab"
    fi
}

function _sdc_rbac_install_shard()
{
    local dbname=$1
    local shard=$2
    local dbdir
    local srcdir

    case "$dbname" in
    exec_attr|prof_attr)
        dbdir="/etc/security/${dbname}_attr.d"
        srcdir="/opt/smartdc/boot$dbdir"
        ;;
    *)
        fatal "Unknown rbac(5) database name: $dbname"
        ;;
    esac

    if ! /usr/bin/mkdir -p "$dbdir"; then
        fatal "Could not create rbac(5) database shard directory \"$dbdir\""
    fi

    /usr/bin/rm -f "$dbdir/$shard"
    if ! /usr/bin/cp "$srcdir/$shard" "$dbdir/$shard"; then
        fatal "Could not install rbac(5) shard \"$shard\" from \"$srcdir\""
    fi

    #
    # The "svc:/system/rbac:default" service is a transient service that merges
    # any updated shard files into the primary file for each rbac(5) database.
    # When installing a new shard file, we restart it synchronously to ensure
    # the primary database file is up to date.
    #
    _sdc_restart_smf_service 'svc:/system/rbac:default'
}

#
# Sets up RBAC profiles for access to zone metadata, and imports the pfexec SMF
# service.
#
function _sdc_mdata_rbac_setup()
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
    _sdc_enable_smf_service 'svc:/system/pfexec:default'
    _sdc_enable_smf_service 'svc:/system/rbac:default'

    _sdc_rbac_install_shard 'prof_attr' 'mdata'
    _sdc_rbac_install_shard 'exec_attr' 'mdata'
}

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
#     Set to "true" if SAPI is in proto mode.
#
function sdc_common_setup()
{
    _sdc_load_variables

    printf 'Performing setup of "%s" zone...\n' "${ZONE_ROLE}"

    _sdc_create_dcinfo
    _sdc_install_bashrc
    _sdc_setup_amon_agent
    _sdc_log_rotation_setup
    _sdc_mdata_rbac_setup

    if [[ ! -f /var/svc/setup_complete ]]; then
        if [[ ${ZONE_ROLE} != "assets" ]]; then
            if [[ ${ZONE_ROLE} == "sapi" && "${SAPI_PROTO_MODE}" == \
              "true" ]]; then
                echo "Skipping config-agent/SAPI instance setup: 'sapi' " \
                  "zone in proto mode"
            else
                setup_config_agent
                download_metadata
                write_initial_config
                registrar_setup
            fi
        fi
    else
        echo "Already setup, skipping SAPI and registrar initialization."
    fi

    _sdc_enable_cron
}

#
# Create the setup_complete file and prepare to copy the log. This should be
# called as the last thing before setup exits.
#
function sdc_setup_complete()
{
    touch /var/svc/setup_complete
    echo "setup done"

    # we copy the log in the background in 5 seconds so that we get the exit
    # in the log.
    (sleep 5; cp /var/svc/setup.log /var/svc/setup_init.log) &
}

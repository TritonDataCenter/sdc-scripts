#!/usr/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2014, Joyent, Inc.
#

#
# Usage in a SDC core zone "boot/setup.sh" file:
#
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

# TODO(HEAD-1983): finish validating using these with all SDC core zones.
#set -o errexit
#set -o pipefail


function fatal() {
    echo "error: $*" >&2
    exit 1
}


function _sdc_load_variables()
{
    export ZONE_ROLE=$(mdata-get sdc:tags.smartdc_role)
    [[ -n "${ZONE_ROLE}" ]] || fatal "Unable to find zone role in metadata."
}

function _sdc_create_dcinfo()
{
    # Setup "/.dcinfo": info about the datacenter in which this zone runs
    # (used for a more helpful PS1 prompt).
    local dc_name=$(mdata-get sdc:datacenter_name)
    if [[ $? == 0 && -z ${dc_name} ]]; then
        dc_name="UNKNOWN"
    fi
    [[ -n ${dc_name} ]] && echo "SDC_DATACENTER_NAME=\"${dc_name}\"" > /.dcinfo
}

function _sdc_install_bashrc()
{
    if [[ -f /opt/smartdc/boot/etc/root.bashrc ]]; then
        cp /opt/smartdc/boot/etc/root.bashrc /root/.bashrc
    fi
}

function _sdc_setup_amon_agent()
{
    if [[ ! -f /var/svc/setup_complete && -d /opt/amon-agent ]]; then
        # Install and start the amon-agent.
        (cd /opt/amon-agent && ./pkg/postinstall.sh)
        rm -f /var/svc/amon-agent.tgz
    fi
}


function setup_config_agent()
{
    local prefix=/opt/smartdc/config-agent
    if [[ ! -d $prefix ]]; then
        return
    fi

    echo "Setting up config-agent"
    local sapi_url=$(mdata-get sapi-url)
    local tmpfile=/tmp/agent.$$.xml

    sed -e "s#@@PREFIX@@#${prefix}#g" \
        ${prefix}/smf/manifests/config-agent.xml > ${tmpfile}
    mv ${tmpfile} ${prefix}/smf/manifests/config-agent.xml

    mkdir -p ${prefix}/etc
    local file=${prefix}/etc/config.json
    cat >${file} <<EOF
{
    "logLevel": "info",
    "pollInterval": 60000,
    "sapi": {
        "url": "${sapi_url}"
    }
}
EOF

    # Caller of setup.common can set 'CONFIG_AGENT_LOCAL_MANIFESTS_DIRS'
    # to have config-agent use local manifests.
    if [[ -n "${CONFIG_AGENT_LOCAL_MANIFESTS_DIRS}" ]]; then
        for dir in ${CONFIG_AGENT_LOCAL_MANIFESTS_DIRS}; do
            local tmpfile=/tmp/add_dir.$$.json
            cat ${file} | json -e "
                this.localManifestDirs = this.localManifestDirs || [];
                this.localManifestDirs.push('$dir');
                " >${tmpfile}
            mv ${tmpfile} ${file}
        done
    fi
}

# Add a directory in which to search for local config manifests
function config_agent_add_manifest_dir
{
    local file=/opt/smartdc/config-agent/etc/config.json
    local dir=$1

    local tmpfile=/tmp/add_dir.$$.json

    cat ${file} | json -e "this.localManifestDirs.push('$dir')" >${tmpfile}
    mv ${tmpfile} ${file}
}

# SAPI-224: This was dropped, however we keep a stub here to not break
# the call to 'upload_values' in the SAPI zone from headnode.sh in the
# GZ in case we get a mix of old-headnode.sh + new-sapi-image.
#
# After some reasonable period, this stub could be dropped.
function upload_values()
{
    echo "Warning: 'upload_values' is deprecated."
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

# Download this zone's SAPI metadata and save it in a local file.
# TODO: Drop support for this. Zones needs this should get it themselves.
function download_metadata()
{
    local admin_mac
    admin_mac=$(mdata-get sdc:nics | json -c 'this.nic_tag==="admin"' 0.mac)
    if [[ -z "${admin_mac}" ]]; then
        echo "Skipping download of SAPI metadata: don't have admin NIC"
        return
    fi

    export METADATA=/var/tmp/metadata.json
    echo "Downloading SAPI metadata to ${METADATA}"
    local sapi_url=$(mdata-get sapi-url)

    curl -s ${sapi_url}/configs/$(zonename) | json metadata > ${METADATA}
    # TODO(HEAD-1983): This won't work: json pipe looses retval.
    if [[ $? -ne 0 ]]; then
        fatal "failed to download metadata from SAPI"
    fi
}

function write_initial_config()
{
    local prefix=/opt/smartdc/config-agent
    if [[ ! -d $prefix ]]; then
        return
    fi

    echo "Writing initial SAPI manifests."
    # Write configuration synchronously
    ${prefix}/build/node/bin/node ${prefix}/agent.js -s

    svccfg import ${prefix}/smf/manifests/config-agent.xml
    svcadm enable config-agent
}

# SAPI-255: This was dropped, however we keep a stub here to not break
# the call to 'sapi_adopt' in the SAPI zone from headnode.sh in the
# GZ in case we get a mix of old-headnode.sh + new-sapi-image.
#
# After some reasonable period, this stub could be dropped.
function sapi_adopt()
{
    echo "Warning: 'sapi_adopt' is deprecated."
}

function registrar_setup()
{
    if [[ ! -d /opt/smartdc/registrar ]]; then
        return
    fi

    local manifest=/opt/smartdc/registrar/smf/manifests/registrar.xml
    local config=/opt/smartdc/registrar/etc/config.json

    if [[ -f ${manifest} ]]; then
        [[ -f ${config} ]] || fatal "No registrar config for ${ZONE_ROLE}"

        echo "Importing and enabling registrar"
        svccfg import ${manifest} || fatal "failed to import registrar"
        svcadm enable registrar || fatal "failed to enable registrar"
    fi
}

function _sdc_enable_cron()
{
    # HEAD-1367 - Enable Cron. Since all zones using this are joyent-minimal,cron
    # is not enable by default. We want to enable it though, for log rotation.
    echo "Starting Cron"
    svccfg import /lib/svc/manifest/system/cron.xml
    svcadm enable cron
}


function _sdc_log_rotation_setup {
    mkdir -p /var/log/sdc/upload
    chown root:sys /var/log/sdc
    chown root:sys /var/log/sdc/upload

    # Ensure that log rotation HUPs *r*syslog.
    logadm -r /var/adm/messages
    logadm -w /var/adm/messages -C 4 -a 'kill -HUP `cat /var/run/rsyslogd.pid`'
}

# Add an entry to /etc/logadm.conf for hourly log rotation of important sdc
# logs.
#
# Usage:
#   sdc_logadm_add <name> <file-pattern> [<size-limit>]
#
# "<name>" is a short string (spaces and '_' are NOT allowed) name for
# this log set. "<file-pattern>" is the path to the file (or a file pattern)
# to rotate. If a pattern it should resolve to a single file -- i.e. allowing
# a pattern is just for convenience. "<size-limit>" is an optional upper size
# limit on all the rotated logs. It corresponds to the '-S size' argument in
# logadm(1m).
#
# Examples:
#   sdc_log_rotation_add amon-agent /var/svc/log/*amon-agent*.log 1g
#   sdc_log_rotation_add imgapi /var/svc/log/*imgapi*.log 1g
#
function sdc_log_rotation_add {
    [[ $# -ge 1 ]] || fatal "sdc_log_rotation_add requires at least 1 argument"
    local name=$1
    [[ -n "$(echo "$name" | (egrep '(_| )' || true))" ]] \
        && fatal "sdc_log_rotation_add 'name' cannot include spaces or underscores: '$name'"
    local pattern="$2"
    local size=$3
    local extra_opts=
    if [[ -n "$size" ]]; then
        extra_opts="$extra_opts -S $size"
    fi
    logadm -w $name $extra_opts -C 168 -c -p 1h \
        -t "/var/log/sdc/upload/${name}_\$nodename_%FT%H:%M:%S.log" \
        -a "/opt/smartdc/boot/sbin/postlogrotate.sh ${name}" \
        "$pattern" || fatal "unable to create $name logadm entry"
}

# TODO(HEAD-1365): Once ready for all sdc zones, move this to sdc_setup_complete
function sdc_log_rotation_setup_end {
    # Move the smf_logs entry to run last (after the entries we just added) so
    # that the default '-C 3' doesn't defeat our attempts to save out.
    logadm -r smf_logs
    logadm -w smf_logs -C 3 -c -s 1m '/var/svc/log/*.log'

    crontab=/tmp/.sdc_log_rotation_end-$$.cron
    # Remove the existing default daily logadm.
    crontab -l | sed '/# Rotate system logs/d; /\/usr\/sbin\/logadm$/d' >$crontab
    [[ $? -eq 0 ]] || fatal "Unable to write to $crontab"
    grep logadm $crontab >/dev/null \
        && fatal "Not all 'logadm' references removed from crontab"
    echo '' >>$crontab
    # Add an hourly logadm.
    echo '0 * * * * /usr/sbin/logadm' >>$crontab
    crontab $crontab
    [[ $? -eq 0 ]] || fatal "Unable import crontab"
    rm -f $crontab
}

# Sets up RBAC profiles for access to zone metadata, and imports the
# pfexec SMF service.
function _sdc_mdata_rbac_setup()
{
    svccfg import /lib/svc/manifest/system/pfexecd.xml
    svcadm enable pfexec
    cat > /etc/security/prof_attr.d/mdata <<EOF
Metadata Reader:::Read access to zone metadata:help=Metadata.html
Metadata Writer:::Write access to zone metadata:help=Metadata.html
EOF
    cat /etc/security/prof_attr.d/mdata >> /etc/security/prof_attr
    cat > /etc/security/exec_attr.d/mdata <<EOF
Metadata Reader:solaris:cmd:::/usr/sbin/mdata-get:privs=file_dac_search
Metadata Reader:solaris:cmd:::/usr/sbin/mdata-list:privs=file_dac_search
Metadata Writer:solaris:cmd:::/usr/sbin/mdata-put:privs=file_dac_search
Metadata Writer:solaris:cmd:::/usr/sbin/mdata-delete:privs=file_dac_search
EOF
    cat /etc/security/exec_attr.d/mdata >> /etc/security/exec_attr
}


# Main entry point for an SDC core zone's "setup.sh". See top-comment.
#
# Optional input envvars:
#   CONFIG_AGENT_LOCAL_MANIFESTS_DIRS=<space-separated-list-of-local-manifest-dirs>
#   SAPI_PROTO_MODE=<true>
#
function sdc_common_setup()
{
    _sdc_load_variables
    echo "Performing setup of ${ZONE_ROLE} zone"
    _sdc_create_dcinfo
    _sdc_install_bashrc
    _sdc_setup_amon_agent
    _sdc_log_rotation_setup
    _sdc_mdata_rbac_setup

    if [[ ! -f /var/svc/setup_complete ]]; then
        if [[ ${ZONE_ROLE} != "assets" ]]; then
            if [[ ${ZONE_ROLE} == "sapi" && "${SAPI_PROTO_MODE}" == "true" ]]; then
                echo "Skipping config-agent/SAPI instance setup: 'sapi' zone in proto mode"
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

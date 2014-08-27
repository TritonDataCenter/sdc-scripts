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

# echo a true or false value
function _bool() {
    local bool_val
    if [[ $1 == "true" ]]; then
        bool_val=$1
    else
        bool_val="false"
    fi

    echo ${bool_val}
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
    if [[ ! -f /var/svc/setup_complete ]]; then
        # Install and start the amon-agent.
        (cd /opt/amon-agent && ./pkg/postinstall.sh)
        rm -f /var/svc/amon-agent.tgz
    fi
}

function _sapi_load_variables()
{
    SAPI_URL=$(mdata-get sapi-url)
    [[ -z ${SAPI_URL} ]] && fatal "Unable to mdata-get sapi_url"
}

function sapi_get() {
    local i
    local rc
    local path=$1

    [[ -z ${SAPI_URL} ]] && _sapi_load_variables

    i=0
    rc=1
    while [[ -${rc} -ne 0 && ${i} -lt 48 ]]; do
        curl ${SAPI_URL}${path} -sS -H accept:application/json
        rc=$?
        i=$((${i} + 1))
    done
}

function sapi_put() {
    local i
    local rc
    local path=$1
    local payload=$2

    [[ -z ${SAPI_URL} ]] && _sapi_load_variables

    i=0
    rc=1
    while [[ -${rc} -ne 0 && ${i} -lt 48 ]]; do
        curl ${SAPI_URL}${path} -sS -H accept:application/json -X PUT \
            -H content-type:application/json \
            -d "${payload}"
        rc=$?
        i=$((${i} + 1))
    done
}

function setup_config_agent()
{
    echo "Setting up SAPI config-agent"
    local sapi_url=$(mdata-get sapi-url)
    local prefix=/opt/smartdc/config-agent
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

# Upload the IP addresses assigned to this zone into its metadata
function upload_values()
{
    echo "Updating IP metadata in SAPI"
    local update=/opt/smartdc/config-agent/bin/mdata-update

    # Let's assume a zone will have at most four NICs
    for i in $(seq 0 3); do
        local ip=$(mdata-get sdc:nics.${i}.ip)
        [[ $? -eq 0 ]] || ip=""
        local tag=$(mdata-get sdc:nics.${i}.nic_tag)
        [[ $? -eq 0 ]] || tag=""

        # Want tag name to be uppercase
        tag=$(echo ${tag} | tr 'a-z' 'A-Z')

        if [[ -n ${ip} && -n ${tag} ]]; then
            # If the update fails because this is a binder, it's because sapi
            # won't take writes while it is in full mode and dependencies are
            # down.
            ${update} ${tag}_IP ${ip}
            if [[ $? -ne 0 ]] && [[ "$ZONE_ROLE" != 'binder' ]]; then
                fatal "failed to upload ${tag}_IP metadata"
            fi

            if [[ $i == 0 ]]; then
                ${update} PRIMARY_IP ${ip}
                if [[ $? -ne 0 ]] && [[ "$ZONE_ROLE" != 'binder' ]]; then
                  fatal "failed to upload PRIMARY_IP metadata"
                fi
            fi
        fi
    done
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
function download_metadata()
{
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
    echo "Writing initial SAPI manifests."
    local prefix=/opt/smartdc/config-agent
    # Write configuration synchronously
    ${prefix}/build/node/bin/node ${prefix}/agent.js -s

    svccfg import ${prefix}/smf/manifests/config-agent.xml
    svcadm enable config-agent
}


# "sapi_adopt" means adding an "instance" record to SAPI's DB for this
# instance.
function sapi_adopt()
{
    if [[ ${ZONE_ROLE} != "assets" && ${ZONE_ROLE} != "sapi" ]]; then
        sapi_instance=$(curl -s $(mdata-get sapi-url)/instances/$(zonename) | \
                        json -H uuid)
    fi

    if [[ -z ${sapi_instance} ]]; then
        # adopt this instance
        sapi_url=$(mdata-get sapi-url)

        local service_uuid=""
        local i=0
        while [[ -z ${service_uuid} && ${i} -lt 48 ]]; do
            service_uuid=$(curl ${sapi_url}/services?name=${ZONE_ROLE}\
                -sS -H accept:application/json | json -Ha uuid)
            if [[ -z ${service_uuid} ]]; then
                echo "Unable to get server_uuid from sapi yet.  Sleeping..."
                sleep 5
            fi
            i=$((${i} + 1))
        done
        [[ -n ${service_uuid} ]] || \
            fatal "Unable to get service_uuid for role ${ZONE_ROLE} from SAPI"

        uuid=$(zonename)
        alias=$(mdata-get sdc:alias)

        i=0
        while [[ -z ${sapi_instance} && ${i} -lt 48 ]]; do
            sapi_instance=$(curl ${sapi_url}/instances -sS -X POST \
                -H content-type:application/json \
                -d "{ \"service_uuid\" : \"${service_uuid}\", \"uuid\" : \"${uuid}\", \"params\": { \"alias\": \"${alias}\" } }" \
                | json -H uuid)
            if [[ -z ${sapi_instance} ]]; then
                echo "Unable to adopt ${uuid} into sapi yet.  Sleeping..."
                sleep 5
            fi
            i=$((${i} + 1))
        done

        [[ -n ${sapi_instance} ]] || fatal "Unable to adopt ${uuid} into SAPI"
        echo "Adopted service ${alias} to instance ${uuid}"
    fi
}

function registrar_setup()
{
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

    if [[ ! -f /var/svc/setup_complete ]]; then
        echo "Initializing SAPI metadata and config-agent"

        if [[ ${ZONE_ROLE} != "assets" && ${ZONE_ROLE} != "sapi" ]]; then
            sapi_adopt
        fi

        if [[ ${ZONE_ROLE} != "assets" ]]; then
            if [[ ${ZONE_ROLE} == "sapi" && "${SAPI_PROTO_MODE}" == "true" ]]; then
                echo "Skipping config-agent/SAPI instance setup: 'sapi' zone in proto mode"
            else
                setup_config_agent
                upload_values
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

#
# Register this service as requiring load-balancing
#
function lb_register()
{
    local http=$(_bool $1)
    local https=$(_bool $2)
    local ports=$3
    local external=$(_bool $4)
    local internal_http=$(_bool $5)

    local app_uuid
    local lbs
    local lbs_after
    local node=/opt/smartdc/config-agent/build/node/bin/node
    local sapi_url
    local svc_domain

    if [[ ${http} == "false" && ${https} == "false" && -z ${ports} ]]; then
        fatal "Must specify one of http, https, or ports"
    fi

    _sapi_load_variables

    app_uuid=$(sapi_get /applications?name=sdc | \
        json 0.uuid)
    [[ -z ${app_uuid} ]] && fatal "Unable to get sdc application from SAPI"

    [[ -z ${METADATA} ]] && download_metadata

    svc_domain=$(json -f ${METADATA} SERVICE_DOMAIN)
    [[ -z ${svc_domain} ]] && fatal "Can't find SERVICE_DOMAIN in ${METADATA}"

    lbs=$(sapi_get /applications/${app_uuid} | \
        json -o json-0 -H metadata.LB_SERVICES)

    lbs_after=$(echo "${lbs}" | ${node} -e "
        var boolParams = {
            external: ${external},
            http: ${http},
            https: ${https},
            internalHttp: ${internal_http}
        };
        var found = false;
        var lbSvcs = [];
        var ports = [ ${ports} ].sort();
        var svcDomain = \"${svc_domain}\";

        var stdin = require('fs').readFileSync('/dev/stdin').toString();

        if (stdin && stdin != '\n') {
            lbSvcs = JSON.parse(stdin);
        }


        function svcMatches(svc) {
            var p;
            // Don't stomp on our original copy of svc - we'll output that
            // at the end of this file
            var tmpSvc = {};

            if (svc.domain != svcDomain) {
                return false;
            }

            for (p in boolParams) {
                if (svc.hasOwnProperty(p)) {
                    tmpSvc[p] = svc[p];
                } else {
                    tmpSvc[p] = false;
                }

                if (boolParams[p] != tmpSvc[p]) {
                    return false;
                }
            }

            if (svc.hasOwnProperty('tcpPorts')) {
                tmpSvc.tcpPorts = svc.tcpPorts.map(function (p) {
                    return p;
                }).sort();
            } else {
                tmpSvc.tcpPorts = [];
            }

            if (tmpSvc.tcpPorts.toString() != ports.toString()) {
                return false;
            }

            return true;
        }

        for (var s in lbSvcs) {
            delete lbSvcs[s].last;
            if (!found && svcMatches(lbSvcs[s])) {
                found = true;
            }
        }

        if (!found) {
            var newSvc = { domain: svcDomain, last: true };

            if (ports.length !== 0)
                newSvc.tcpPorts = ports;

            for (var b in boolParams) {
                if (boolParams[b])
                    newSvc[b] = true;
            }

            lbSvcs.push(newSvc);
            console.log(JSON.stringify({
                metadata: {
                    LB_SERVICES: lbSvcs
                }
            }));
        }
    ")

    if [[ -n ${lbs_after} ]]; then
        echo "Adding domain ${svc_domain} (mode ${mode}${port_msg})"
        echo sapi_put /applications/${app_uuid} ${lbs_after}
        sapi_put /applications/${app_uuid} ${lbs_after}
    else
        echo "Domain ${svc_domain} (mode ${mode}${port_msg}) is already in SAPI: not adding"
    fi
}

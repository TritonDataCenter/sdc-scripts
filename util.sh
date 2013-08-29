#!/usr/bin/bash
#
# Copyright (c) 2013, Joyent Inc. All rights reserved.
#

function fatal() {
    echo "error: $*" >&2
    exit 1
}

#
# This loads:
#
# sapi_url (when zone_role != sapi)
# zone_role (and ZONE_ROLE)
# zone_uuid
#
function sdc_load_variables()
{
    zone_uuid=$(zonename)
    zone_role=$(mdata-get sdc:tags.smartdc_role)
    [[ -z ${zone_role} ]] && fatal "Unable to find zone role in metadata."

    # If we're not SAPI, we need to know where SAPI is.
    if [[ ${zone_role} != "sapi" ]]; then
        sapi_url=$(mdata-get sapi-url)
        [[ -z ${sapi_url} ]] && fatal "Unable to find IP of SAPI in metadata"
    fi

    # XXX we probably shouldn't need zone_role and ZONE_ROLE
    export ZONE_ROLE="${zone_role}"
}

function sdc_create_dcinfo()
{
    # Setup "/.dcinfo": info about the datacenter in which this zone runs
    # (used for a more helpful PS1 prompt).
    local dc_name=$(mdata-get sdc:datacenter_name)
    if [[ $? == 0 && -z ${dc_name} ]]; then
        dc_name="UNKNOWN"
    fi
    [[ -n ${dc_name} ]] && echo "SDC_DATACENTER_NAME=\"${dc_name}\"" > /.dcinfo
}

function sdc_setup_amon_agent()
{
    if [[ ! -f /var/svc/setup_complete ]]; then
        # Install and start the amon-agent.
        (cd /opt/amon-agent && ./pkg/postinstall.sh)
        rm -f /var/svc/amon-agent.tgz
    fi
}

# Write out the config-agent's file
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
    "pollInterval": 15000,
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
            ${update} ${tag}_IP ${ip}
            if [[ $? -ne 0 ]]; then
                fatal "failed to upload ${tag}_IP metadata"
            fi

            if [[ $i == 0 ]]; then
                ${update} PRIMARY_IP ${ip}
                if [[ $? -ne 0 ]]; then
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

# Download this zone's SAPI metadata and save it in a local file
function download_metadata()
{
    export METADATA=/var/tmp/metadata.json
    echo "Downloading SAPI metadata to ${METADATA}"
    local sapi_url=$(mdata-get sapi-url)

    curl -s ${sapi_url}/configs/$(zonename) | json metadata > ${METADATA}
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

# XXX - can be removed when sdc-role is backed by SAPI.
function sapi_adopt()
{
    if [[ ${ZONE_ROLE} != "assets" && ${ZONE_ROLE} != "sapi" ]]; then
        sapi_instance=$(curl -s $(mdata-get sapi-url)/instances/$(zonename) | \
                        json -H uuid)
    fi

    ## non-sapi services will be necessarily created by sdc-role
    ## at this point, so we need to adopt them.
    if [[ -z ${sapi_instance} ]]; then
        # adopt this instance
        sapi_url=$(mdata-get sapi-url)
        service_uuid=$(curl ${sapi_url}/services?name=${ZONE_ROLE}\
            -sS -H accept:application/json | json -Ha uuid)
        uuid=$(zonename)
        sapi_instance=$(curl ${sapi_url}/instances -sS -X POST \
            -H content-type:application/json \
            -d "{ \"service_uuid\" : \"${service_uuid}\", \"uuid\" : \"${uuid}\" }" \
            | json -H uuid)

        [[ -n ${sapi_instance} ]] || fatal "Unable to adopt ${ZONE_NAME} into SAPI"
        echo "Adopted service ${ZONE_NAME} to instance ${uuid}"
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

function sdc_enable_cron()
{
    # HEAD-1367 - Enable Cron. Since all zones using this are joyent-minimal,cron
    # is not enable by default. We want to enable it though, for log rotation.
    echo "Starting Cron"
    svccfg import /lib/svc/manifest/system/cron.xml
    svcadm enable cron
}

function sdc_common_setup()
{
    sdc_load_variables
    sdc_create_dcinfo
    sdc_setup_amon_agent

    if [[ ! -f /var/svc/setup_complete ]]; then
        echo "Initializing SAPI metadata and config-agent"

        if [[ ${ZONE_ROLE} != "assets" && ${ZONE_ROLE} != "sapi" ]]; then
            sapi_adopt
            setup_config_agent
            upload_values
            download_metadata
            write_initial_config
            registrar_setup
        fi
    else
        echo "Already setup, skipping SAPI and registrar initialization."
    fi

    sdc_enable_cron
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

#!/bin/bash
# ******************************************************************************
# IBM Cloud Kubernetes Service, 5737-D43
# (C) Copyright IBM Corp. 2017, 2021 All Rights Reserved.
#
# SPDX-License-Identifier: Apache2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ******************************************************************************
set -e
SCRIPT_DIR=$(dirname "${BASH_SOURCE[0]}")
# import shared common bash functions
# NOTE(cjschaef): shellcheck can't handle the recommended solution, ignore it
# shellcheck disable=SC1090
. "${SCRIPT_DIR}/scripts/common_functions.sh"

K8S_CURRENT_VERSION=$(grep "^TAG " Makefile | awk '{ print $3 }')
if [[ -z "${K8S_CURRENT_VERSION}" ]]; then
    echo "FAIL: Unable to determine current Kubernetes version in Makefile."
    exit 1
fi

# $1: Kubernetes update version
K8S_UPDATE_VERSION="${1}"
if [[ -z "${K8S_UPDATE_VERSION}" ]]; then
    if [[ $TRAVIS_EVENT_TYPE == "cron" ]]; then
        # Trim alpha/beta tag off of current release
        K8S_SHORT_VERSION=${K8S_CURRENT_VERSION%-*}
        # Looking up update version manually for updater cron job
        MAJOR_MINOR=${K8S_SHORT_VERSION%.*}
        K8S_UPDATE_VERSION=$(curl https://api.github.com/repos/kubernetes/kubernetes/releases | jq -r .[].name | grep "$MAJOR_MINOR" | head -1  | sed 's/^Kubernetes //g')
        MOD_VERSION=$(go mod download -json "k8s.io/api@kubernetes-${K8S_UPDATE_VERSION#v}" | jq -r .Version)
        if [[ -z "${K8S_UPDATE_VERSION}" ]]; then
            echo "FAIL: Failed to retrieve latest kubernetes version."
            exit 1
        fi
        if [[ "${K8S_UPDATE_VERSION}" == "${K8S_CURRENT_VERSION}" ]]; then
            echo "INFO: No new version available, exiting gracefully"
            exit 0
        fi
        # Ensure the go modules have also been updated. i.e. k8s.io/api v0.20.3
        if [[ "${MOD_VERSION}" != "v0.${K8S_UPDATE_VERSION#*.}" ]]; then
            echo "INFO: New go modules are not yet available, exiting gracefully"
            exit 0
        fi
    else
        echo "FAIL: Kubernetes update version not set."
        exit 1
    fi
fi

# Get the IBM current and update versions based on the Kubernetes versions.
IBM_CURRENT_VERSION=$(echo "${K8S_CURRENT_VERSION}" | cut -c 2- | awk -F. '{ print "release-"$1"."$2 }')
IBM_UPDATE_VERSION=$(echo "${K8S_UPDATE_VERSION}" | cut -c 2- | awk -F. '{ print "release-"$1"."$2 }')

echo "INFO: Starting Kubernetes update from version ${K8S_CURRENT_VERSION} to ${K8S_UPDATE_VERSION} ..."
make clean

K8S_DIRECTORY="/tmp/kubernetes"
if [[ ! -e "${K8S_DIRECTORY}" ]]; then
    git clone --depth=1 --no-single-branch https://github.com/kubernetes/kubernetes.git ${K8S_DIRECTORY}
fi
git -C ${K8S_DIRECTORY} checkout master && git -C ${K8S_DIRECTORY} remote update && git -C ${K8S_DIRECTORY} pull --ff-only origin master

# Determine the current and update golang version.
git -C "${K8S_DIRECTORY}" checkout "${K8S_CURRENT_VERSION}"
K8S_GOLANG_CURRENT_VERSION=$(grep -A 1 "name: \"golang: upstream version" "${K8S_DIRECTORY}/build/dependencies.yaml" | grep "version:" | awk '{ print $2 }')
git -C "${K8S_DIRECTORY}" checkout "${K8S_UPDATE_VERSION}"
K8S_GOLANG_UPDATE_VERSION=$(grep -A 1 "name: \"golang: upstream version" "${K8S_DIRECTORY}/build/dependencies.yaml" | grep "version:" | awk '{ print $2 }')

# Update files based on Kubernetes and IBM release versions.
ALL_FILES=$(find . \( -path ./.git -o -path ./kube-update.sh -o -path './go.*' \) -prune -o \( -type f -print \) )
# shellcheck disable=SC2086
FILES_TO_UPDATE_FOR_K8S_VERSION=$(grep -l -F "${K8S_CURRENT_VERSION}" $ALL_FILES)
# shellcheck disable=SC2086
FILES_TO_UPDATE_FOR_IBM_VERSION=$(grep -l -F "${IBM_CURRENT_VERSION}" $ALL_FILES)
for FILE_TO_UPDATE_FOR_K8S_VERSION in $FILES_TO_UPDATE_FOR_K8S_VERSION; do
    sed -i -e "s/${K8S_CURRENT_VERSION}/${K8S_UPDATE_VERSION}/g" "${FILE_TO_UPDATE_FOR_K8S_VERSION}"
    git add "${FILE_TO_UPDATE_FOR_K8S_VERSION}"
    echo "INFO: Updated Kubernetes version in ${FILE_TO_UPDATE_FOR_K8S_VERSION}"
done
for FILE_TO_UPDATE_FOR_IBM_VERSION in $FILES_TO_UPDATE_FOR_IBM_VERSION; do
    sed -i -e "s/${IBM_CURRENT_VERSION}/${IBM_UPDATE_VERSION}/g" "${FILE_TO_UPDATE_FOR_IBM_VERSION}"
    git add "${FILE_TO_UPDATE_FOR_IBM_VERSION}"
    echo "INFO: Updated IBM version in ${FILE_TO_UPDATE_FOR_IBM_VERSION}"
done

if [[ "${K8S_GOLANG_CURRENT_VERSION}" != "${K8S_GOLANG_UPDATE_VERSION}" ]]; then
    FILES_TO_UPDATE=".travis.yml vagrant-kube-build/Vagrantfile"
    for FILE_TO_UPDATE in $FILES_TO_UPDATE; do
        if [[ "${FILE_TO_UPDATE}" == ".travis.yml" ]]; then
            sed -i -e "s/^  - ${K8S_GOLANG_CURRENT_VERSION}/  - ${K8S_GOLANG_UPDATE_VERSION}/g" "${FILE_TO_UPDATE}"
            sed -i -e "s/go:\s\+${K8S_GOLANG_CURRENT_VERSION}/go: ${K8S_GOLANG_UPDATE_VERSION}/g" "${FILE_TO_UPDATE}"
        else
            sed -i -e "s/${K8S_GOLANG_CURRENT_VERSION}/${K8S_GOLANG_UPDATE_VERSION}/g" "$FILE_TO_UPDATE"
        fi
        git add "$FILE_TO_UPDATE"
        echo "INFO: Updated golang version in $FILE_TO_UPDATE"
    done
fi

COMMIT_MESSAGE="Update from ${K8S_CURRENT_VERSION} to ${K8S_UPDATE_VERSION}"
git checkout -b "${K8S_UPDATE_VERSION}-initial"
git commit --no-verify -m "${COMMIT_MESSAGE}"
if [[ $TRAVIS_EVENT_TYPE == "cron" ]]; then
    # Setup hub to allow PR's
    # User and token come from Travis environment variables
    mkdir -p ~/.config
    cat >~/.config/hub <<EOF
github.ibm.com:
- protocol: https
  user: $GHE_USER
  oauth_token: $GHE_TOKEN
EOF

    # Open pull request from travis cron job
    curl -OL https://github.com/github/hub/releases/download/v2.14.2/hub-linux-amd64-2.14.2.tgz
    tar -xzvf hub-linux-amd64-2.14.2.tgz
    rm -f hub-linux-amd64-2.14.2.tgz
    cd hub-linux-amd64-2.14.2
    sudo ./install
    git config --global --add hub.host github.ibm.com

    hub pull-request -b "${TRAVIS_BRANCH}" -m "${COMMIT_MESSAGE}" --push
else
    # Otherwise push up branch for manual runs
    git push origin "${K8S_UPDATE_VERSION}-initial"
fi

echo "SUCCESS: Completed Kubernetes update from version ${K8S_CURRENT_VERSION} to ${K8S_UPDATE_VERSION}."
exit 0

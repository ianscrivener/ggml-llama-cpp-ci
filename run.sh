#!/bin/bash

# usage: run.sh node

if [ -z "${1}" ]; then
    printf "run.sh : usage: run.sh node\n"
    exit 1
fi

if [ ! -f ~/.env.sh ]; then
    printf "run.sh : ~/.env.sh is not found\n"
    exit 1
fi

sd=`dirname $0`

source $sd/env.sh
source ~/.env.sh

GG_NODE=${1}

# check if results repo is cloned

if [ ! -d ${GG_RESULTS_PATH} ]; then
    printf "run.sh : results repo is not cloned\n"
    exit 1
fi

# check if GG_SECRET_TOKENGH_API env is empty

if [ -z "${GG_SECRET_TOKEN_GH_API}" ]; then
    printf "run.sh : GG_SECRET_TOKEN_GH_API env is not set\n"
    exit 1
fi

# check if the script is already running

if [ -f /tmp/ggml-lock ]; then
    printf "run.sh : script is already running\n"
    exit 1
fi

# create a lock file

touch /tmp/ggml-lock

function gg_cleanup {
    rm -f /tmp/ggml-lock
}

# delete the lock file on exit

trap gg_cleanup EXIT


## main

# get last N commits from a branch
function gg_get_last_commits {
    branch=$1
    N=$2

    git log origin/${branch} -n ${N} --pretty=format:"%H" --abbrev-commit
}

# get last N commits from all branches that contain a keyword
function gg_get_last_commits_grep {
    keyword=$1
    N=$2

    git log --all --grep="${keyword}" -n ${N} --pretty=format:"%H" --abbrev-commit
}

function gg_commit_results {
    repo=$1

    wd=$(pwd)

    cd ${GG_RESULTS_PATH}

    git add .
    git commit -m "$repo : ${GG_NODE}"

    for i in $(seq 1 ${GG_RUN_PUSH_RETRY}); do
        git pull --rebase
        git push

        if [ $? -eq 0 ]; then
            break
        fi
    done

    cd ${wd}
}

function gg_run_ggml {
    repo="ggml"

    cd ${GG_WORK_PATH}/${GG_GGML_DIR}

    git fetch --all > /dev/null 2>&1

    branches="master"

    if [ -f ${GG_WORK_BRANCHES} ]; then
        branches=$(cat ${GG_WORK_BRANCHES} | grep "^${repo}" | cut -d' ' -f2-)
    fi

    printf "run.sh : processing '${repo}' branches - '${branches}'\n"

    commits=""

    for branch in ${branches} ; do
        commits="${commits} $(gg_get_last_commits ${branch} ${GG_RUN_LAST_N})"
    done

    commits="${commits} $(gg_get_last_commits_grep ${GG_CI_KEYWORD} ${GG_RUN_LAST_N})"

    for hash in ${commits} ; do
        out=${GG_RESULTS_PATH}/${repo}/${GG_NODE}/${hash}

        if [ -d ${out} ]; then
            continue
        fi

        gg_set_commit_status "${GG_NODE}" "${GG_GGML_OWN}" "${repo}" "${hash}" "pending" "in queue ..."
    done

    for hash in ${commits} ; do
        out=${GG_RESULTS_PATH}/${repo}/${GG_NODE}/${hash}

        if [ -d ${out} ]; then
            continue
        fi

        printf "run.sh : processing '${repo}' commit ${hash}\n"

        gg_set_commit_status "${GG_NODE}" "${GG_GGML_OWN}" "${repo}" "${hash}" "pending" "running ..."

        mkdir -p ${out}

        git checkout ${hash}
        git submodule update --init --recursive
        git clean -fd

        timeout ${GG_RUN_TIMEOUT} time bash ci/run.sh ${out} > ${out}/stdall 2>&1
        result=$?

        echo ${result} > ${out}/exit

        if [ ${result} -eq 0 ]; then
            gg_set_commit_status "${GG_NODE}" "${GG_GGML_OWN}" "${repo}" "${hash}" "success" "success"
        else
            gg_set_commit_status "${GG_NODE}" "${GG_GGML_OWN}" "${repo}" "${hash}" "failure" "failure ${result}"
        fi

        printf "run.sh : done processing '${repo}' commit ${hash}, result ${result}\n"

        gg_commit_results "${repo}"
    done
}

# main loop

while true; do
    gg_run_ggml

    sleep ${GG_RUN_SLEEP}
done

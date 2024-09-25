#!/bin/bash -e
result_file="announcement.md"
medik8s_tag_prefix="https://github.com/medik8s"
template_prefix="# Medik8s New Releases

The Medik8s team is thrilled to announce the new "
template_notes_sentence="
See our website, https://www.medik8s.io/, for the latest information on the team's"
template_suffix="

Feel free to use the new operators and contact us for any help.

Best regards on behalf of the Medik8s team,"

create_template() {
    local operator_names operator_versions
    local -a list_operators_names=("${1:-}")
    local -a list_versions=("${2:-}")

    # Convert input strings to arrays
    eval "names=(${list_operators_names})"
    eval "versions=(${list_versions})"

    # shellcheck disable=SC2068
    if [ -z "${names}" ] || [ -z "${versions}" ] ; then
        echo "There are no operators/versions to mention. Please try again"
        exit 1
    fi
    if [ ${#names[@]} -ne ${#versions[@]} ]; then
        echo "Lists must have the same length."
        exit 1
    fi
    if [ ${#names[@]} -eq 1 ] || [ ${#versions[@]} -eq 1 ]; then
        operator_names="release of "
        operator_versions="${template_notes_sentence} operator, and see our release note for the complete list of changes: "
    else
        operator_names+="releases of "
        operator_versions="${template_notes_sentence} operators, and see our release notes for the complete list of changes: "
    fi

    for ((i=0; i<${#names[@]}; i++)); do
        name=${names[$i]}
        version=${versions[$i]}
        local tag_link
        case "${name}" in
            nhc)
                operator_names+="Node Healthcheck Operator (NHC) v${version}, "
                tag_link="${medik8s_tag_prefix}/node-healthcheck-operator/releases/tag/v${version}"
                operator_versions+="[NHC v${version}](${tag_link}),"
                ;;
            snr)
                operator_names+="Self Node Remediation (SNR) v${version}, "
                tag_link="${medik8s_tag_prefix}/self-node-remediation/releases/tag/v${version}"
                operator_versions+="[SNR v${version}](${tag_link}),"
                ;;
            far)
                operator_names+="Fence Agents Remediation (FAR) v${version}, "
                tag_link="${medik8s_tag_prefix}/fence-agents-remediation/releases/tag/v${version}"
                operator_versions+="[FAR v${version}](${tag_link}),"
                ;;
            mdr)
                operator_names+="Machine Deletion Remediation (MDR) v${version}, "
                tag_link="${medik8s_tag_prefix}/machine-deletion-remediation/releases/tag/v${version}"
                operator_versions+="[MDR v${version}](${tag_link}),"
                ;;
            nmo)
                operator_names+="Node Maintenance Operator (NMO) v${version}, "
                tag_link="${medik8s_tag_prefix}/node-maintenance-operator/releases/tag/v${version}"
                operator_versions+="[NMO v${version}](${tag_link}),"
                ;;
            *)
                echo "Unexepcted operator name. Please try again"
                exit 1
                ;;
        esac
    done
    echo "${template_prefix}${operator_names}${operator_versions}${template_suffix}" > "${result_file}" 
}

# TODO: add validate_semantic_version and maybe validate with curl the tag_link
# validate_semantic_version(){
# 
# }

create_template "$@"

#!/bin/bash
#Run from inside of either CloudShell or a Bastion VM inside of the same GCP project as the GCP cnuc's
###

ERROR_COLOR="\e[1;31m"
INFO_COLOR="\e[1;37m"
WARN_COLOR="\e[1;33m"
DEBUG_COLOR="\e[1;35m"
DEFAULT_COLOR="\e[1;32m"
ENDCOLOR="\e[0m"

PREFIX_DIR=$(dirname -- "$0")
source ${PREFIX_DIR}/scripts/cloud/gce-helper.vars

function pretty_print() {
    MSG=$1
    LEVEL=${2:-DEFAULT}

    if [[ -z "${MSG}" ]]; then
        return
    fi

    case "$LEVEL" in
        "DEFAULT")
            echo -e $(printf "${DEFAULT_COLOR}${MSG}${ENDCOLOR}")
            ;;
        "ERROR")
            echo -e $(printf "${ERROR_COLOR}${MSG}${ENDCOLOR}")
            ;;
        "WARN")
            echo -e $(printf "${WARN_COLOR}${MSG}${ENDCOLOR}")
            ;;
        "INFO")
            echo -e $(printf "${INFO_COLOR}${MSG}${ENDCOLOR}")
            ;;
        "DEBUG")
            echo -e $(printf "${DEBUG_COLOR}${MSG}${ENDCOLOR}")
            ;;
        *)
            echo "NO MATCH"
            ;;
    esac
}

### Results in none or one key for the current Instance Run to download. If emtpy, no key to down
function get_downloadable_key_name {
	# NOTE: This matches ansible's setting for ssh key download
	local SSH_SECRET_NAME_PREFIX="ssh-priv-key-"

	# First check if there is a key in the GCP Secret Manager
	SECRET_LIST=$(gcloud secrets list --filter="name~${SSH_SECRET_NAME_PREFIX}" --format="value(name)" --project="${PROJECT_ID}"  2> /dev/null)

	echo ""
	pretty_print "NOTE: There are existing keys in Google Secrets for this project (${PROJECT_ID})" "DEBUG"
    echo ""
    SECRET_COUNT=${#SECRET_LIST[@]}
	for index in ${!SECRET_LIST[@]}; do
        cluster_name=${SECRET_LIST[$index]#"$SSH_SECRET_NAME_PREFIX"}
        num=$(( index + 1 ))
		pretty_print "  $num) ${cluster_name}" "DEBUG"
	done
    # Add option for "create a new key"
	pretty_print "  $((num+1))) Create a new key-pair" "DEBUG"
	echo ""
	pretty_print "  Ctl+C to cancel" "DEBUG"
    # Start capture of decision
    echo ""
	read -p "Which of these do you want to use: " sel_key_num

	if [[ "${sel_key_num}" =~ ^([1-9][0-9]*)$ ]] && [[ "${sel_key_num}" -le $((SECRET_COUNT+1)) ]] ; then
        if [[ "${sel_key_num}" -le SECRET_COUNT ]]; then
            echo ""
    		pretty_print "INFO: Downloading key for ${SECRET_LIST[$index]#}" "INFO"
            gcloud secrets versions access latest --secret="${SECRET_LIST[$index]}" >> ./build-artifacts/consumer-edge-machine --project="${PROJECT_ID}"
			chmod 600 ./build-artifacts/consumer-edge-machine
            pretty_print "INFO: Generate the public key locally ./build-artifacts/consumer-edge-machine.pub" "INFO"

            ssh-keygen -f ./build-artifacts/consumer-edge-machine -y >> ./build-artifacts/consumer-edge-machine.pub
        else
            echo ""
            echo "INFO: Creating a new SSH key-pair and pushing to Google Secret Manager for Cluster '${DEFAULT_CLUSTER_NAME}'"
            echo "INFO: The new primary key stored at ./build-artifacts/consumer-edge-machine.pub"

            ssh-keygen -o -a 100 -t ed25519 -f ./build-artifacts/consumer-edge-machine -N ''
            gcloud secrets create ssh-priv-key-${DEFAULT_CLUSTER_NAME} --replication-policy="automatic" > /dev/null 2>&1 # Ignore all issues with this
            gcloud secrets versions add ssh-priv-key-${DEFAULT_CLUSTER_NAME} --data-file="build-artifacts/consumer-edge-machine" > /dev/null 2>&1
        fi
    else
        echo ""
        pretty_print "ERROR: The answer [${sel_key_num}] was not recognized, please re-run." "ERROR"
        echo ""
        exit 1
	fi
}

# Option to add the cluster name to the script
DEFAULT_CLUSTER_NAME=${1:-cnuc-1}
if [[ "${DEFAULT_CLUSTER_NAME}" =~ ^([a-z]+[0-9a-z-]*)$ ]]; then
	pretty_print "INFO: Evaluating setup using cluster name [${DEFAULT_CLUSTER_NAME}]" "INFO"
else
	pretty_print "ERROR: Cluster name [$DEFAULT_CLUSTER_NAME] contains characters that cannot be used. Only lowercase alpha-numeric and dashes can be used" "ERROR"
	exit 1
fi

# Must currently run as an admin user with org permissions in order to make the changes throughout
# For now this means we will require that the user login via gcloud auth login
# This check will bail if a gserviceaccount is found in use
ACTIVE_USER=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
GSERVICEACCOUNT=$(echo ${ACTIVE_USER} | grep gserviceaccount)
if [[ ! -z "${GSERVICEACCOUNT}" ]]; then
	echo "Detected gcloud is authenticated using a GSA. Please login as a human user account using the following command -- 'gcloud auth login --no-launch-browser'"
	echo "Copy/Paste the link into a browser where you are authenticated with admin level permissions for the project!!"
	exit 1
fi

# detect Argolis user
ARGOLIS_USER=$(echo ${ACTIVE_USER} | grep "altostrat.com")
IS_ARGOLIS=false
if [[ ! -z "${ARGOLIS_USER}" || ! -z "${ARGOLIS_PROJECT}" ]]; then
	pretty_print "INFO: Detected this is an Argolis project and will attempt to modify org policies to enable Consumer Edge." "DEBUG"
	IS_ARGOLIS=true
fi

pretty_print "Beginning Installation!" "INFO"

# If there is an existing PROJECT_ID defined, do not redefine it
if [[ -z "${PROJECT_ID}" ]]; then
	PROJECT_ID=$(gcloud config list --format 'value(core.project)' 2>/dev/null)
fi
pretty_print "INFO: Using ${PROJECT_ID} as the target GCP Project" "INFO"
# Needed for reference
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

pretty_print "INFO: Enabling GCP services requried for project" "INFO"

if [[ ${IS_ARGOLIS} == true ]]; then
	source ./scripts/argolis-setup.sh
fi

# enable any services needed
gcloud services enable servicemanagement.googleapis.com \
	anthos.googleapis.com cloudbuild.googleapis.com \
	cloudresourcemanager.googleapis.com serviceusage.googleapis.com \
	compute.googleapis.com secretmanager.googleapis.com --quiet --verbosity=critical --no-user-output-enabled

pretty_print "INFO: Adding roles/secretmanager.secretAccessor and roles/storage.objectViewer to default compute service account." "INFO"
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor" --no-user-output-enabled

pretty_print "INFO: Adding roles/storage.objectViewer to default compute service account." "INFO"
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="roles/storage.objectViewer" --no-user-output-enabled

pretty_print "INFO: Adding roles/storage.objectViewer to default cloudbuild service account." "INFO"
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
    --role="roles/storage.objectViewer" --no-user-output-enabled

ERROR=0
if [[ ! -x $(command -v gcloud) ]]; then
    pretty_print "ERROR: gcloud (Google Cloud SDK) command is required, but not installed." "ERROR"
    ERROR=1
else
    pretty_print "PASS: gcloud command found"
fi

if [[ ! -x $(command -v docker) ]]; then
    pretty_print "ERROR: docker command is required, but not installed." "ERROR"
    ERROR=1
else
    pretty_print "PASS: docker command found"
fi

if [[ ! -x $(command -v jq) ]]; then
    pretty_print "ERROR: jq command is required, but not installed." "ERROR"
    ERROR=1
else
    pretty_print "PASS: jq command found"
fi

if [[ ! -x $(command -v git) ]]; then
    pretty_print "ERROR: git command is required, but not installed." "ERROR"
    ERROR=1
else
    pretty_print "PASS: git command found"
fi

if [[ ! -x $(command -v screen) ]]; then
    pretty_print "ERROR: screen command is required, but not installed." "ERROR"
    ERROR=1
else
    pretty_print "PASS: screen command found"
fi

if [[ "${ERROR}" -eq 1 ]]; then
	ERROR=0 # Reset
	pretty_print "=========================" "ERROR"
	pretty_print "Some or all required dependencies are not met." "INFO"
	read -p "Would you like this script to install the required dependencies? (Y/N) " -n 1 -r
	echo
	if [[ "${REPLY}" =~ ^([yY][eE][sS]|[yY])$ ]]; then
		sudo apt update
		if [[ ! -x $(command -v screen) ]]; then
			pretty_print "Installing screen" "INFO"
			set +x
			sudo apt -y install screen
		fi

		if [[ ! -x $(command -v git) ]]; then
			pretty_print "Installing git" "INFO"
			set +x
			sudo apt -y install git
		fi

		if [[ ! -x $(command -v docker) ]]; then
			pretty_print "Installing docker" "INFO"

			sudo apt -y remove docker docker-engine docker.io containerd runc
			sudo apt -y install ca-certificates curl gnupg lsb-release
			curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --yes --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
			echo \
				"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian \
					$(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
			sudo apt update
			sudo apt -y install docker-ce docker-ce-cli containerd.io
			sudo usermod -aG docker $(whoami)
			sudo chmod 666 /var/run/docker.sock
			echo "Finished Docker setup..."
		fi

		if [[ ! -x $(command -v jq) ]]; then
			pretty_print "Installing jq" "INFO"
			sudo apt -y install jq -y
		fi

		if [[ ! -x $(command -v direnv) ]]; then
			pretty_print "Installing direnv" "INFO"
			sudo apt -y install unzip direnv
			echo 'eval "$(direnv hook bash)"' >> ~/.bashrc
			source ~/.bashrc
			direnv allow
		fi
	else
		pretty_print "Exiting. Please fix depenencies on your own or re-run and select 'Y'" "ERROR"
		exit 1
	fi
fi

# Start screen configuration & session
echo "termcapinfo xterm* ti@:te@" > .screenrc

SSH_KEY_LOC="./build-artifacts/consumer-edge-machine"
### Setup SSH Keys on local box (create new or download from GCP Secret Manager)
if [[ ! -f "./build-artifacts/consumer-edge-machine" ]]; then
	get_downloadable_key_name
fi

# Print the public key (not sensitive)
PUB_KEY=$(cat ${SSH_KEY_LOC}.pub)
pretty_print "INFO: Public key-pair used: ${PUB_KEY}" "INFO"

export QL_PROJECT_ID=$(gcloud config get-value project 2> /dev/null)
if [[ -z "${QL_PROJECT_ID}" ]]; then
		pretty_print "ERROR: Project ID not configured for gcloud. Please set project with 'gcloud config set project <project-id>'" "ERROR"
        exit 1
	else
		pretty_print "INFO: Setting PROJECT_ID: ${PROJECT_ID}" "INFO"
		export PROJECT_ID="${QL_PROJECT_ID}"
fi

pretty_print ""
pretty_print "==============================="
pretty_print ""
pretty_print "All of the following variables CAN and SHOULD be verified in the generated '.envrc' file following the completion of this script"
pretty_print ""

export ROOT_REPO_URL="https://gitlab.com/gcp-solutions-public/retail-edge/primary-root-repo-template.git"
pretty_print "INFO: Setting default Primary Root Repo: ${ROOT_REPO_URL}" "INFO"

pretty_print "INFO: Setting up docker configuration to use gcloud for gcr.io" "INFO"
yes Y | gcloud auth configure-docker --quiet --verbosity=critical --no-user-output-enabled

if [[ ! -f ".envrc" ]]; then
	pretty_print "INFO: Generating '.envrc' properties file" "INFO"
	envsubst "${PROJECT_ID}" < templates/envrc-template.sh > .envrc
else
	pretty_print "PASS: Using existing .envrc file"
fi
direnv allow .

if [[ ! -f "./build-artifacts/provisioning-gsa.json" ]]; then
	pretty_print "INFO: Create the provisioning GSAs used during initial setup. JSON key placed in ./build-artifacts/" "INFO"
	yes Y | ./scripts/create-gsa.sh
else
	pretty_print "PASS: GSA Keys have been created for the provisioning GSA"
fi

# Create docker container for buildling
CONTAINER_URL=$(gcloud container images list --repository=gcr.io/${PROJECT_ID} --format="value(name)" --filter="name~consumer-edge-install")
if [[ -z "$CONTAINER_URL" ]]; then
	pretty_print "INFO: This project uses a Docker image to provision host machines from. The image has not been detected and will be built (takes about 10 minutes)" "INFO"
	gcloud builds submit --config ./docker-build/cloudbuild.yaml ./ --quiet --verbosity=critical --no-user-output-enabled
else
	pretty_print "INFO: Docker build image was found, will not re-build automatically." INFO
fi

if [[ ! -f "inventory/gcp.yml" ]]; then
	pretty_print "INFO: Default GCP Ansible plugin configuration was not found. Generating a new version at inventory/gcp.yml" "INFO"
	envsubst < templates/inventory-cloud-example.yaml > inventory/gcp.yml
else
	pretty_print "PASS: GCP Inventory file found at inventory/gcp.yml"
fi

echo ""
echo ""
pretty_print "Your project is set up and ready for use. You will need to do a combination of the following options next:"
echo ""
pretty_print "Cloud-based host machines (default)" "DEBUG"
pretty_print "1. Create GCE instances: run './scripts/cloud/create-cloud-gce-baseline.sh -c 3'" "INFO"
pretty_print "2. Use your editor of choice and check the generated '.envrc' file to ensure correct Environment Variables were set."
pretty_print "3. If you made any changes, save file and run either: 'direnv allow .' or 'source .envrc'"
pretty_print "4. Run: ./install.sh "
echo ""
pretty_print "Physical Machine based host machines" "DEBUG"
pretty_print "1. Double check the .envrc file to make sure the variables are staticly defined and are correct." "INFO"
pretty_print "2. If you made any changes, 'direnv allow .'"
pretty_print "3. Copy the 3 'edge-X.yaml' files in ./inventory and rename with a hostname of your choice (ie: nucs-1.yaml, nucs-2.yaml, nucs-3.yaml)"
pretty_print "4. If using physical hardware, create an inventory file: envsubst < templates/inventory-physical-example.yaml > inventory/inventory.yaml."
pretty_print "   - Modify this file to match your host_var inventory files (see previous step). Comment out 'edge-1,edge-2,edge-3 and replace with your host names"
pretty_print "5. Run: ./install.sh "
echo ""
pretty_print "NOTE: Physical machines require a bit more setup not outlined here. Please ping the go/gdc-consumer-edge:gchat team for more info."
echo ""
echo ""

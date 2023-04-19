# Overview

This is a utility docker image that is intended to minimize the installation effort for practitioners to build Anthos Edge. The provided Docker image contains all of the dependencies for buildling the Consumer Edge so a developer does not need to modify their development machine (except have `gcloud` installed and configured)

To use this utility, follow the steps outlined below.

1. Satisfy local machine (provisioning machine) requirements
1. Build the image and optionally push to GCP Project Google Cloud Repository (gcr.io)
1. Pull & verify image
1. Start instance of Docker image

## 1. Local machine requirements
* Docker machine (ie: Docker for Desktop 20.0+ or similar)
* `gcloud` configured on local machine
* GCP Project w/ billing enabled
* Setup an ENV variable for `PROJECT_ID` to match the GCP project

## 2. Build image

There are two methods to build this docker image, please choose one:

> NOTE: In some future state, there will be a public docker image, but until that time, a GCP project will need to host the Docker image.

1. Cloud Build (preferred)

    Cloud Build allows you to build the docker image without needing to build docker images on the provisioning machine.

    ```bash
    gcloud builds submit --config ./docker-build/cloudbuild.yaml ./
    ```

1. Manual docker commands (optional)

    Building locally can be helpful when developing or making quick changes to the docker image, or just prefer to not pull from GCR.

    ```bash
    # Build for local only
    pushd docker-build/  # go into docker-build, push current directory on stack
    docker build . -t consumer-edge-install:latest
    popd  # pop back to previoud directory
    ```

    ### Optionally push to GCR manually

    If you have [docker authenticated to GCR](https://cloud.google.com/sdk/gcloud/reference/auth/configure-docker), you can run these commands

    ```bash
    docker build . -t gcr.io/${PROJECT_ID}/consumer-edge-install
    docker push gcr.io/${PROJECT_ID}/consumer-edge-install
    ```

## 3. Pull and validate image

**IF** the image was pushed to the GCP Project's GCR, then you need to pull the image down (done once per change to the image)

1. Pull the latest consumer-edge-installer image

    ```bash
    # Pull from gcr.io
    docker pull gcr.io/${PROJECT_ID}/consumer-edge-install:latest
    ```

1. Run the image locally

    The docker image needs a few paramters to run in order to expose the project's filesystem contents and the GCP project. There are two options to running the image, choose one method.

    > NOTE: All commands should be run **FROM** the project's root direction, **NOT** inside `build-docker/`

    ### 1a. Automated run image (preferred)
    ```bash
    ./install.sh
    ```

    ### 1b. Manually run image

    ```bash
    docker run -e PROJECT_ID=${PROJECT_ID} -v "$(pwd):/var/consumer-edge-install:ro" -it gcr.io/${PROJECT_ID}/consumer-edge-install:latest
    ```

## Troubleshooting

### `(gcloud.auth.activate-service-account) Unable to read file`


This presents when starting the container with the following message:

```
ERROR: (gcloud.auth.activate-service-account) Unable to read file [./build-artifacts consumer-edge-gsa.json]: [Errno 2] No such file or directory: './build-artifacts/consumer-edge-gsa.json'
```

This is the result of now using two Google Service Accounts (GSAs) in this solution: *provisioning*, which is used by this Docker container for the purposes of provisioning ABM onto the cluster nodes; and *node*, which persists on the cluster nodes and is *not* used by Docker container.  This resulted in a rename of the GSA which was activated when the container starts.

To fix this, rebuild your Docker container after updating your branch with the latest changes in the `main` branch.

## Update requirements.txt

1. Change all `==` to `>=`
1. Add any new dependencies (optional) using the same `>=` known version
1. Set the Ansible version of choice (ie: 6.7.0)
1. Run the compiler `pip-compile --allow-unsafe --generate-hashes requirements.txt --resolver=backtracking`
1. Review and save file


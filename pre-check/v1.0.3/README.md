# Pre-check scripts before an upgrade

We have developed a script to assist in verifying if a cluster is eligible for a smooth upgrade. Please follow the steps below to utilize the script:

## Usage

1. Log in to a control plane node and switch to the root user:

    ```
    ssh rancher@<ip>
    sudo -i
    ```

1. Execute the following command to initiate the check:

    ```
    curl -sLf https://raw.githubusercontent.com/harvester/upgrade-helpers/main/pre-check/v1.0.3/check.sh -o check.sh
    chmod +x check.sh
    ./check.sh
    ```

    The check script will provide an output similar to the following:

    ```
    >>> Check all bundles ready...
    All Helm bundles are ready.
    >>> Check the Harvester bundle is ready...
    The Harvester bundle is ready.
    >>> Check all nodes are ready...
    All nodes are ready.
    >>> Check the CAPI cluster is provisioned...
    The CAPI cluster is provisioned.
    >>> Check the CAPI machines are running...
    The CAPI machines are provisioned.
    >>> Check Longhorn volumes...
    All volumes are healthy.
    >>> Check stale Longhorn volumes...
    Checking volume longhorn-system/pvc-c664716b-9e3a-4693-a91e-14ede2afb0cd...
    Checking volume longhorn-system/pvc-ff113f82-702e-46ba-9c0c-bd11ece4ac33...
    There is no stale Longhorn volume.
    >>> Check error pods...
    All pods are OK.
    All nodes have more than 30GB free space.
    
    All checks pass.
    ```

    If any checks fail, please refrain from proceeding with the upgrade.


### Check time is in sync on every node.

If there is no NTP server configured, please log in to each node and check the time is in sync (with `date` command).


# Pre-check scripts before an upgrade

We build a script to help check if a cluster can do a smooth upgrade.

## Usage

1. Log in to a control plane node and become root:

    ```
    ssh rancher@<ip>
    sudo -i
    ```

1. Execute this command to check:

    ```
    curl -sLf https://raw.githubusercontent.com/harvester/upgrade-helpers/pre-check/v1.0.3/check.sh -o check.sh
    chmod +x check.sh
    ./check.sh
    ```

    The check script should have a output like:

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

    If there are any failing check, please do not proceed the upgrade.


## Other checks

These are some additional checks to do.

### Check time is in sync on every node.

If there is no NTP server configured, please log in to each node and check the time is in sync (with `date` command).


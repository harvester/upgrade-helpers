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
    curl -sLf https://raw.githubusercontent.com/harvester/upgrade-helpers/main/pre-check/v1.1.x/check.sh -o check.sh
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
    >>> Check CAPI cluster is not paused...
    CAPI cluster is not paused.
    >>> Check the CAPI machines count...
    CAPI machine count is equal to node count.
    >>> Check the CAPI machines are running...
    The CAPI machines are provisioned.
    >>> Check Longhorn volumes...
    Skip checking for single node cluster.
    >>> Check stale Longhorn volumes...
    There is no stale Longhorn volume.
    >>> Check error pods...
    All pods are OK.
    Error from server (NotFound): services "rancher-monitoring-prometheus" not found
    Error: no matches found
    Prometheus service not found. Skipping free space check.
    >>> Check control plane certificates...
    >>> Checking kube-controller-manager certificate...
    Certificate will not expire
    kube-controller-manager certificate expires in 364 days (Apr 17 10:07:51 2027 GMT)
    >>> Checking kube-scheduler certificate...
    Certificate will not expire
    kube-scheduler certificate expires in 364 days (Apr 17 10:07:51 2027 GMT)

    All checks pass.
    ```

    If any checks fail, please refrain from proceeding with the upgrade.


### Check time is in sync on every node.

If there is no NTP server configured, please log in to each node and check the time is in sync (with `date` command).


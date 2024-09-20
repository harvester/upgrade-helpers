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
    curl -sLf https://raw.githubusercontent.com/harvester/upgrade-helpers/main/pre-check/v1.x/check.sh -o check.sh
    chmod +x check.sh
    ./check.sh
    ```

    The check script will provide an output similar to the following:

    ```
    # ./check.sh -l log.txt
    ==============================
    
    Starting Host check...
    Host Test: Pass
    
    ==============================
    
    Starting Certificates check...
    Certificates Test: Pass
    
    ==============================
    
    Starting Node Free Space check...
    Node-Free-Space Test: Pass
    
    ==============================
    
    Starting Helm Bundle status check...
    Helm-Bundles Test: Pass
    
    ==============================
    
    Starting Harvester Bundle status check...
    Harvester-Bundles Test: Pass
    
    ==============================
    
    Starting Node Status check...
    Node-Status Test: Pass
    
    ==============================
    
    Starting CAPI Cluster State check...
    CAPI-Cluster-State Test: Pass
    
    ==============================
    
    Starting CAPI Machine Count check...
    CAPI-Machine-Count Test: Pass
    
    ==============================
    
    Starting CAPI Machine State check...
    CAPI-Machine-State Test: Pass
    
    ==============================
    
    Starting Longhorn Volume Health Status check...
    Longhorn-Volume-Health-Status Test: Pass
    
    ==============================
    
    Starting Stale Longhorn Volumes check...
    Stale-Longhorn-Volumes Test: Pass
    
    ==============================
    
    Starting Pod Status check...
    Pod-Status Test: Pass
    
    ==============================
    
    Starting Node Free Space check...
    Node-Free-Space Test: Pass
    
    ==============================
    
    Starting Kubeconfig Secret check...
    Kubeconfig Secret Test: Pass
    
    ==============================
    
    All checks have passed.
    ```

    If any checks fail, please refrain from proceeding with the upgrade. You can obtain additional information by running the script again with the verbose flag (`./check.sh -v`) or with logging enabled (ie: `./check.sh -l log.txt`). Running the scipt with the `-h` flag can provide additional information and options. 


### Check time is in sync on every node.

If there is no NTP server configured, please log in to each node and check the time is in sync (with `date` command).


#!/usr/bin/env python3

import re
import os
import sys
import shutil
import argparse
from datetime import datetime
from subprocess import check_output, DEVNULL

# /sys/class/net/enp1s0f0/device/modalias
sys_net_path = '/sys/class/net'
is_pci_bridge_pattern = r"pci:.*sc04.*"
is_v238_pattern = r"ID_NET_NAMING_SCHEME=v238"
have_name_slot_pattern = r"ID_NET_NAME_SLOT=(.*)"
have_name_onboard_pattern = r"ID_NET_NAME_ONBOARD=(.*)"
have_name_path_pattern = r"ID_NET_NAME_PATH=(.*)"
custom_yaml_name = '/oem/99_custom.yaml'

bond_pattern = r'(BONDING_SLAVE_\d+)='
quote_pattern = r'''['"]'''
ifcfg_pattern = r'(/etc/sysconfig/network/ifcfg-)'

def main(really_want_to_do=False):
    print("migrate v238 to sle15-sp3")

    # backup 99_custom.yaml to same folder with timestamp
    if really_want_to_do:
        now = datetime.now().isoformat(timespec='seconds')
        backup_yaml_name = f"{custom_yaml_name}.bk-{now}"
        shutil.copy(custom_yaml_name, backup_yaml_name)
        print(f"backup {custom_yaml_name} to {backup_yaml_name}")

    origin = ""
    mode = 'r'
    if really_want_to_do:
        mode = 'r+'
    with open(custom_yaml_name, mode) as f:
        origin = f.read()

        # scan all physical NICs
        for nic in os.listdir(sys_net_path):
            print('---')
            print(f"scan {nic}")
            # phys NIC will have device symlink to pci device
            if not os.path.exists(os.path.join(sys_net_path, nic, 'device')):
                print(f"{nic} is not physical NIC, skip")
                continue
            udev_str = check_output(['udevadm', 'test-builtin', 'net_id', f'{sys_net_path}/{nic}'], stderr=DEVNULL).decode('ascii')
            #print(udev_str)

            if not re.search(is_v238_pattern, udev_str):
                print(f"name scheme is not v238")
                continue

            # ignore onboard
            if re.search(have_name_onboard_pattern, udev_str):
                print(f"{nic} is onboard, skip")
                continue

            # ignore if no slot name
            m = re.search(have_name_slot_pattern, udev_str)
            if not m:
                print(f"{nic} is not ID_NET_NAME_SLOT, skip")
                continue

            # slot name and path name exist
            slot_name = m.group(1)
            path_name = re.search(have_name_path_pattern, udev_str).group(1)

            # skip if already used path_name
            if nic == path_name:
                print(f"{nic} is path_name, skip")
                continue

            # check is PCI bridge
            with open(os.path.join(sys_net_path, nic, 'device', 'modalias'), 'r') as f:
                modalias = f.read()
                print(modalias)
                if not re.search(is_pci_bridge_pattern, modalias):
                    print(f"{nic} is not assocated with PCI bridge")
                    continue

            print(f"need to migrate {nic} to {path_name}")
            origin = re.sub(bond_pattern + quote_pattern + nic + quote_pattern, r"\1=" + f"'{path_name}'", origin)
            origin = re.sub(ifcfg_pattern + nic, r"\1" + path_name, origin)

        if really_want_to_do:
            f.seek(0)
            f.write(origin)
            f.truncate()
        else:
            print(origin)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()

    # always dry run until --really-want-to-do option on
    parser.add_argument("--really-want-to-do", help="start patch",action="store_true")
    args = parser.parse_args()

    main(args.really_want_to_do)

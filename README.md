# Ladder

## WireGuard

wget https://gist.githubusercontent.com/virtual-world-0923/a8967d3c82f40e9c2699d428728d363d/raw/41ef9962f783810b89a9d48dece426e0da3d424f/install-WireGuard.sh



wget https://gist.githubusercontent.com/virtual-world-0923/95b7cafa6b433ad437481d0c01c04823/raw/6047710e3490ca6d5c6d0e0c75d0e5a9a76f0cfa/purge-WireGuard.sh



## amneziaWG

wget https://gist.githubusercontent.com/virtual-world-0923/61d902b23f7b85febbe78012d2d22054/raw/2bdc98d69a90b34649401a1528fde801de00ff27/install_amneziawg_aws.sh



wget https://gist.githubusercontent.com/virtual-world-0923/cc5eeece76ff03cc5fd0f03cc602b0f6/raw/9fcd23d10ab9a25c6f8957132bafe80dd8b18e03/purge_amneziawg_aws.sh



遇到的 DKMS 编译失败，根源在于当前内核版本（`7.0.0-1014-aws`）与 AmneziaWG PPA 源中的模块代码不兼容。这是一个已知问题，主要影响较新的 7.0 系列内核。

执行修复：

wget https://gist.githubusercontent.com/virtual-world-0923/2b073f9bdfb171b7e3a5795c45fbe18a/raw/d5cfaf64665f55ad1231b40b328ba9de191c8f92/repair-amneziawWG-kernel

```shell
The following additional packages will be installed:
  amneziawg amneziawg-tools
The following NEW packages will be installed:
  amneziawg amneziawg-dkms amneziawg-tools
0 upgraded, 3 newly installed, 0 to remove and 8 not upgraded.
Need to get 0 B/397 kB of archives.
After this operation, 2188 kB of additional disk space will be used.
Selecting previously unselected package amneziawg-dkms.
(Reading database ... 85610 files and directories currently installed.)
Preparing to unpack .../amneziawg-dkms_1.0.0-0~202609061402+4569c4c~ubuntu24.04.1_all.deb ...
Unpacking amneziawg-dkms (1.0.0-0~202609061402+4569c4c~ubuntu24.04.1) ...
Selecting previously unselected package amneziawg-tools.
Preparing to unpack .../amneziawg-tools_1.0.20210914-0~202608130144+ee0f0a9~ubuntu24.04.1_amd64.deb ...
Unpacking amneziawg-tools (1.0.20210914-0~202608130144+ee0f0a9~ubuntu24.04.1) ...
Selecting previously unselected package amneziawg.
Preparing to unpack .../amneziawg_1.0.20210914-0~202608130144+ee0f0a9~ubuntu24.04.1_all.deb ...
Unpacking amneziawg (1.0.20210914-0~202608130144+ee0f0a9~ubuntu24.04.1) ...
Setting up amneziawg-tools (1.0.20210914-0~202608130144+ee0f0a9~ubuntu24.04.1) ...
Setting up amneziawg-dkms (1.0.0-0~202609061402+4569c4c~ubuntu24.04.1) ...
Loading new amneziawg-1.0.0 DKMS files...
Deprecated feature: REMAKE_INITRD (/usr/src/amneziawg-1.0.0/dkms.conf)
Building for 7.0.0-1014-aws
Building initial module for 7.0.0-1014-aws
Deprecated feature: REMAKE_INITRD (/var/lib/dkms/amneziawg/1.0.0/source/dkms.conf)
ERROR: Cannot create report: [Errno 17] File exists: '/var/crash/amneziawg-dkms.0.crash'
Error! Bad return status for module build on kernel: 7.0.0-1014-aws (x86_64)
Consult /var/lib/dkms/amneziawg/1.0.0/build/make.log for more information.
dpkg: error processing package amneziawg-dkms (--configure):
 installed amneziawg-dkms package post-installation script subprocess returned error exit status 10
No apport report written because the error message indicates its a followup error from a previous failure.
                                                                                                          dpkg: dependency problems prevent configuration of amneziawg:
 amneziawg depends on amneziawg-dkms (>= 0.0.20200121-2) | amneziawg-modules (>= 0.0.20191219); however:
  Package amneziawg-dkms is not configured yet.
  Package amneziawg-modules is not installed.

dpkg: error processing package amneziawg (--configure):
 dependency problems - leaving unconfigured
Processing triggers for man-db (2.12.0-4build2) ...
Errors were encountered while processing:
 amneziawg-dkms
 amneziawg
needrestart is being skipped since dpkg has failed
E: Sub-process /usr/bin/dpkg returned an error code (1)

```





## xray

wget https://gist.githubusercontent.com/virtual-world-0923/ce897db11ac3410722ed118a05889754/raw/59cc6a86deb74212c283dbbc32cb17dbed305052/install-xray.sh



wget https://gist.githubusercontent.com/virtual-world-0923/eab49bdf327c956159968e2c6de77626/raw/8f8c3d33d77f7405a657cf78f9fa9e9bece9ee11/purge-xray.sh

# UBUNTU for Embedded Systems

Tool to create Ubuntu images for embedded systems (mainly arm boards like the Beaglebone or the Raspberry Pi 2).

**Crash course**

To create an Ubuntu image for the Beaglebone Black:

sudo ./make_img.sh -b beaglebone -d 14.04 -o stack=14.10

To create an Ubuntu image for the RaspberryPi2:

sudo ./make_img.sh -b raspy2 -d 14.04

Serial console: 115200 8N1 - no hardware and software flow control 

Default user / password: ubuntu / ubuntu

See 'boards.db' for an up to date list of supported boards.

Additional options are available through the help section (./make_img.sh -h):

```
[flag@southcross ubuntu-embedded]$ ./make_img.sh -h
usage: make_img.sh -b $BOARD -d $DISTRO [options...]

Available values for:
$BOARD:  beaglexm panda beaglebone mirabox cubox arndale5250 raspy2 versatile-ca9
$DISTRO: 14.04 14.10

Other options:
-f  <device>  device installation target

Misc "catch-all" option:
-o <opt=value[,opt=value, ...]> where:

stack:                  release used for the enablement stack (kernel, bootloader and flask-kernel)
size:                   size of the image file (e.g. 2G, default: 1G)
user:                   credentials of the user created on the target image
passwd:                 same as above, but for the password here
rootfs                  rootfs tar.gz archive (e.g. ubuntu core), can be local or remote (http/ftp)
```

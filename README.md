# The OpenPrinting Printing Stack Snap

Complete CUPS printing stack in a snap

## Introduction

This is a coplete printing stack in a snap. It contains not only CUPS but also cups-filters and Poppler (as the PDF interpreter). This is
everything (except printer-model-specific drivers) which is needed for printing.

This snap is designed for the following three use cases:

1. Providing a printing stack for a purely snap-based operating system, like Ubuntu Core.
2. Providing a printing stack for a classic Linux system, installing the snap instead of the system's usual printing packages.
3. Providing an interface for snaps containing printer drivers. If the user wants to stay with the system's printing stack, the snap runs CUPS in parallel, on an alternative port and shares its print queues to the system's CUPS, as they were a driverless IPP printers.

Note that the snap is still under development and so does not yet fulfill all the design goals.

## Installation and Usage

As long as the snap is not yet in the Snap Store, you have to build it via

```
sudo snapcraft cleanbuild
```

and install it with the command

```
sudo snap install --dangerous <file>.snap
```

with `<file>.snap` being the name of the snap file.

You also need to manually connect the snap to the Avahi interface:
```
sudo snap connect cups:avahi-control
```
This allows sharing of printers between your system's CUPS and the snap's CUPS. cups-browsed (one instance on the system, one in the snap) automatically creates appropriate queues.

The snap's CUPS runs on port 10631.

To use use the snap's command line utilities acting on the snap's CUPS, preceed the commands with `cups.`:
```
cups.lpstat -v
cups.cupsctl
cups.lpadmin -p printer -E -v file:/dev/null
```
You can run administrative commands without `sudo` and without getting asked for a password if you are member of the "adm" group (this is the case for the first user created on a classic Ubuntu system). This is a temporary hack until snapd is able to deal with snap-specific users and groups. This should at least work on classic systems. If this does not work, administrative programs have to run as root (for example running them with `sudo`).

The snap's command line utilities cannot access the user's home directory yet, pipe files from the home directory into the `lp` command to print them:
```
cat <file> | cups.lp -d <printer>
```
The web interface can be accessed under
```
http://localhost:10631/
```
but administrative tasks do not work yet.

You can also access the snap's CUPS with the system's utilities by specifying the server:
```
lpstat -h localhost:10631 -v
```

## Discussion

The development of this snap is discussed on the Snapcraft forum:

* [General development](https://forum.snapcraft.io/t/snapping-cups-printing-stack-avahi-support-system-users-groups/1502)
* [Printer driver plugin snaps](https://forum.snapcraft.io/t/snapping-cups-drivers-as-plugins/1503)

Related topics on the forum:

* [Multiple users and groups in snaps](https://forum.snapcraft.io/t/multiple-users-and-groups-in-snaps/1461)
* [Improvements in the content interface](https://forum.snapcraft.io/t/improvements-in-the-content-interface/2387)

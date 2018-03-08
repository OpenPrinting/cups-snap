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

The printing stack snap works on both classic systems (standard Linux distributions like Ubuntu Desktop) and purely snap-based systems (like Ubuntu Core).

As long as the snap is not yet in the Snap Store, you have to build it via

```
snapcraft cleanbuild
```

and install it with the command

```
sudo snap install --dangerous <file>.snap
```

with `<file>.snap` being the name of the snap file.

You also need to manually connect the snap to the Avahi interface. On classic systems run:
```
sudo snap connect printing-stack-snap:avahi-control
```
On snap-based systems install the Avahi snap at first
```
sudo snap install --edge avahi
```
and connect to the avahi snap:
```
sudo snap connect printing-stack-snap:avahi-control avahi
```
This allows sharing of printers between your system's CUPS and the snap's CUPS. cups-browsed (one instance on the system, one in the snap) automatically creates appropriate queues. Avahi does not yet work completely on snap-based systems as printers on the snap-based system get shared to remote machines but printers on remote machines do not get discovered by the snap-based system.

For USB printer access you need to connect to the raw-usb interface on both classic and snap-based systems:
```
sudo snap connect printing-stack-snap:raw-usb
```

On classic systems the snap has already access to the user's home directory, on a snap-based system you need to run:
```
snap connect printing-stack-snap:home
```

The snap's CUPS runs on port 10631.

To use use the snap's command line utilities acting on the snap's CUPS, preceed the commands with `printing-stack-snap.`:
```
printing-stack-snap.lpstat -v
printing-stack-snap.cupsctl
printing-stack-snap.lpadmin -p printer -E -v file:/dev/null
```
You can run administrative commands without `sudo` and without getting asked for a password if you are member of the "adm" group (this is the case for the first user created on a classic Ubuntu system). This is a temporary hack until snapd is able to deal with snap-specific users and groups. This works on classic systems (you can also add a user to the "adm" group) but not on snap-based systems (the standard user is not in the "adm" group and you cannot add users to the "adm" group). You can always run administrative programs as root (for example running them with `sudo`).

The snap's command line utilities can only access files in the calling user's home directory if they are not hidden (name begins with a dot '`.`'). So you can ususally print with a command like
```
printing-stack-snap.lp -d <printer> <file>
```
For hidden files you have to pipe the file into the command, like with
```
cat <file> | printing-stack-snap.lp -d <printer>
```
or copy or rename the file into a standard file.

The web interface can be accessed under
```
http://localhost:10631/
```
but to make administrative tasks working, you have to run the following commands after installing the snap:
```
sudo chmod 711 /var/snap/cups/current/var/run/certs/
sudo chown root.root /var/snap/cups/current/var/run/certs/
```

You can also access the snap's CUPS with the system's utilities by specifying the server:
```
lpstat -h localhost:10631 -v
```
NOTE: You can also build this snap for CUPS running on the usual port 631, by editing the file `default.yaml` before building the snap, but on classic systems you can then only use the snap after uninstalling the system's CUPS and cups-browsed.


## What is planned/still missing?

* CUPS having its own group ("lpadmin") for administrative tasks, we use "adm" as a workaround.
* Get it into the Snap Store
* Auto-connect to all interfaces (avahi, raw-usb, home).
* Interface for third-party printer driver snaps.
* Auto-selector for the CUPS port: Check during installation whether there is already a CUPS on port 631 or not.
* Provide cups-client slot (for systems without their own CUPS).


## Discussion

The development of this snap is discussed on the Snapcraft forum:

* [General development](https://forum.snapcraft.io/t/snapping-cups-printing-stack-avahi-support-system-users-groups/1502)
* [Printer driver plugin snaps](https://forum.snapcraft.io/t/snapping-cups-drivers-as-plugins/1503)

Related topics on the forum:

* [Multiple users and groups in snaps](https://forum.snapcraft.io/t/multiple-users-and-groups-in-snaps/1461)
* [Improvements in the content interface](https://forum.snapcraft.io/t/improvements-in-the-content-interface/2387)

Getting the snap into the store:

* [Post a snap on behalf of OpenPrinting](https://forum.snapcraft.io/t/post-a-snap-on-behalf-of-openprinting/3757/1)

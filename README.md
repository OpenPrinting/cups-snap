# The OpenPrinting CUPS Snap

Complete CUPS printing stack in a Snap

## Introduction

This is a complete printing stack in a Snap. It contains not only CUPS but also cups-filters, Ghostscript, and Poppler (the two latter as PostScript and PDF interpreters). This is everything (except printer-model-specific drivers) which is needed for printing.

This Snap is designed for the following two use cases:

1. Providing a printing stack for a purely Snap-based operating system, like Ubuntu Core.
2. Providing a printing stack for a classic Linux system, installing the Snap instead of the system's usual printing packages. It is planned that Ubuntu Desktop switches over to use CUPS from this Snap.

Note that this Snap is still under development and therefore there are probably still many bugs.

## Installation and Usage

The CUPS Snap works on both classic systems (standard Linux distributions like Ubuntu Desktop) and purely snap-based systems (like Ubuntu Core).

If on your classic system there is already CUPS running, you do not neccessarily need to stop or remove this CUPS for using the Snap. The Snap's CUPS will run on port 10631 (instead of port 631) then and it will use the domain socket `/var/snap/cups/common/run/cups.sock` (instead of the standard `(/var)/run/cups/cups.sock`). So you can have two CUPS instances (each with their own cups-browsed) on one system, for example for development.

If the Snap's CUPS runs alone, the standard resources, port 631 and `(/var)/run/cups/cups.sock` are used to assure maximum compatibility with both snapped and classically installed client applications.

Note that running two CUPS instances on one system is not recommended on production systems. Disable or remove your system's CUPS if you want to use the Snap's CUPS.

The Snap is available in the Edge channel of the Snap Store and from there one can install it via

```
snap install --edge cups
```

If you want to install from source, you have to build it via

```
snapcraft snap
```

or if this does not work on your system with

```
snapcraft cleanbuild
```

and install it with the command

```
sudo snap install --dangerous <file>.snap
```

with `<file>.snap` being the name of the snap file.

For maximum compatibility with most snapped and unsnapped applications this Snap's CUPS will be accessible through the usual socket /run/cups/cups.sock and port 631.

Only if there is already a CUPS instance running on your system (like one installed via classic Debian or RPM packages), the Snap's CUPS will run on port 10631 and on the /var/snap/cups/common/run/cups.sock domain socket.

If you want to assure that the CUPS Snap will be the only CUPS running on your system and you have a systemd-based system (like Ubuntu), run
```
sudo systemctl stop cups-browsed
sudo systemctl disable cups-browsed
sudo systemctl stop cups
sudo systemctl disable cups
```
before downloading and installing the CUPS Snap. The `stop` commands stop the daemons immediately, the `disable` commands exclude them from being started during boot.

To use use the snap's command line utilities acting on the snap's CUPS, preceed the commands with `cups.`:
```
cuos,lpstat -H
cups.lpstat -v
cups.cupsctl
cups.lpadmin -p printer -E -v file:/dev/null
```
You can run administrative commands without `sudo` and without getting asked for a password if you are member of the "lpadmin" group if it exists on your system, otherwise if you are member of the "adm" group (this is the case for the first user created on a classic Ubuntu system). This works on classic systems (you can also add a user to the "lpadmin" or "adm" group) but not on snap-based systems (the standard user is not in the "adm" group and you cannot add users to the "adm" group). You can always run administrative programs as root (for example running them with `sudo`).

The snap's command line utilities can only access files in the calling user's home directory if they are not hidden (name begins with a dot '`.`'). So you can usually print with a command like
```
cups.lp -d <printer> <file>
```
For hidden files you have to pipe the file into the command, like with
```
cat <file> | cups.lp -d <printer>
```
or copy or rename the file into a standard file.

The web interface can be accessed under
```
http://localhost:631/
```
or
```
http://localhost:10631/
```
To make administrative tasks working, you have to enter user name and password of a user in the "lpadmin" or "adm" group, or "root" and the root password if your system is configured appropriately.

You can also access the snap's CUPS with the system's utilities by specifying the server (example if the snap's CUPS runs in parallel with a system's one, on port 10631 and /var/snap/cups/common/run/cups.sock):
```
lpstat -h localhost:10631 -v
lpstat -h /var/snap/cups/common/run/cups.sock -v
```

For the **very rare** case that you want to do administrative tasks on your
system's classically installed CUPS using the utilities which come with the
CUPS Snap, you need to manually connect the utilities' "cups-internal"
interface:
```
sudo snap connect cups:cups-internal cups:cups-control
```


## What is planned/still missing?

- Spin out cups-browsed into a separate Snap
- Add a script for easy migration from a classically installed CUPS to the
  CUPS Snap


## Change on design goals: Printer drivers deprecated -> Printer Applications

Printer drivers (printer-model-specific software and/or data) in the form of filters and PPD files added to CUPS are deprecated. They get replaced by Printer Applications, simple daemons which emulate a driverless IPP printer on localhost and do the filtering of the incoming jobs and connection to the printer. This daemons will also be packaged in Snaps, to make the driver packages distribution-independent.

Therefore we will not add a printer driver interface as it is not needed any more.

Note that this Snap DOES NOT support classic printer drivers!

If you have a PostScript Printer, do

```
snap install --edge ps-printer-app
```
to get your first Printer Application, the [PostScript Printer Application](https://github.com/OpenPrinting/ps-printer-app).

See "Printer Applications" below.


## Discussion

Call for testing:

* [Call for testing on Snapcraft forum](https://forum.snapcraft.io/t/call-for-testing-openprintings-cups-snap/)
* [Call for testing on Discourse](https://discourse.ubuntu.com/t/cups-snap-call-for-testing/)

Using the CUPS Snap and developing Snaps using it:

* [Printing and managing printers from your Snap](https://forum.snapcraft.io/t/printing-and-managing-printers-from-your-snap/)

The development of this snap is discussed on the Snapcraft forum:

* [General development](https://forum.snapcraft.io/t/snapping-cups-printing-stack-avahi-support-system-users-groups/)
* [Developer sprint Sep 17th, 2018](https://forum.snapcraft.io/t/developer-sprint-sep-17th-2018/)
* [Interface request: “cups-control” on CUPS snap and including D-Bus](https://forum.snapcraft.io/t/interface-request-cups-control-on-cups-snap-and-including-d-bus/)
* [Snapping CUPS Printing Stack: Providing cups-control interface](https://forum.snapcraft.io/t/snapping-cups-printing-stack-providing-cups-control-interface)
* [Snapping CUPS drivers as plugins (DEPRECATED)](https://forum.snapcraft.io/t/snapping-cups-drivers-as-plugins)

Related topics on the forum:

* [Multiple users and groups in snaps](https://forum.snapcraft.io/t/multiple-users-and-groups-in-snaps/)
* [Snapped daemon running as root cannot create file in directory with odd ownerships/permissions](https://forum.snapcraft.io/t/snapped-daemon-running-as-root-cannot-create-file-in-directory-with-odd-ownerships-permissions)
* [Hardware-associated snaps - Snap Store search by hardware signature](https://forum.snapcraft.io/t/hardware-associated-snaps-snap-store-search-by-hardware-signature)
* [User authentication in snapd (pam mediation)](https://forum.snapcraft.io/t/user-authentication-in-snapd-pam-mediation)

Getting the snap into the store:

* [Call for testing: OpenPrinting’s printing-stack-snap (Printing in a Snap) (DEPRECATED)](https://forum.snapcraft.io/t/call-for-testing-openprintings-printing-stack-snap-printing-in-a-snap/)
* [Post a snap on behalf of OpenPrinting](https://forum.snapcraft.io/t/post-a-snap-on-behalf-of-openprinting/)

Printer Applications

* [PostScript Printer Application](https://github.com/OpenPrinting/ps-printer-app)
* [PAPPL](https://github.com/michaelrsweet/pappl/)
* [Printer Applications (PDF)](https://ftp.pwg.org/pub/pwg/liaison/openprinting/presentations/printer-applications-may-2020.pdf)
* [CUPS 2018 (PDF, pages 28-29)](https://ftp.pwg.org/pub/pwg/liaison/openprinting/presentations/cups-plenary-may-18.pdf)
* [CUPS 2019 (PDF, pages 30-35)](https://ftp.pwg.org/pub/pwg/liaison/openprinting/presentations/cups-plenary-april-19.pdf)
* [cups-filters 2018 (PDF, page 11)](https://ftp.pwg.org/pub/pwg/liaison/openprinting/presentations/cups-filters-ippusbxd-2018.pdf)
* [cups-filters 2019 (PDF, pages 16-17)](https://ftp.pwg.org/pub/pwg/liaison/openprinting/presentations/cups-filters-ippusbxd-2019.pdf)
* [cups-filters 2020 (PDF)](https://ftp.pwg.org/pub/pwg/liaison/openprinting/presentations/cups-filters-ippusbxd-2020.pdf)

Snapping of ippusbxd (we should snap [ipp-usb](https://github.com/OpenPrinting/ipp-usb) instead)

* [Feature request: Support for systemd templates](https://forum.snapcraft.io/t/feature-request-support-for-systemd-templates/)

Requests for auto-connection to interfaces

* [Request: CUPS Snap (“cups”) auto connection to of cups:cups-control to cups:cups-control and also of the network-manager-observe interface (accepted)](https://forum.snapcraft.io/t/request-cups-snap-cups-auto-connection-to-of-cups-cups-control-to-cups-admin-and-also-of-the-network-manager-observe-interface/)
* [Request: CUPS Snap (“cups”) auto connection to avahi-control, raw-usb, cups-control, and system-files interfaces (accepted)](https://forum.snapcraft.io/t/request-cups-snap-cups-auto-connection-to-avahi-control-raw-usb-cups-control-and-system-files-interfaces/)
* [Request: Printing Stack Snap auto connection to avahi-control, raw-usb, and home interfaces (DEPRECATED)](https://forum.snapcraft.io/t/request-printing-stack-snap-auto-connection-to-avahi-control-raw-usb-and-home-interfaces)

Links on other platforms:

* [Trello card about adding API to check client Snaps whether they plug a certain interface](https://trello.com/c/9IJToylf/1215-snapd-api-for-checking-client-snaps-whether-they-plug-a-given-interface)
* [Pull Request on snapd for adding the client Snap checking API (merged)](https://github.com/snapcore/snapd/pull/9132)
* [Pull request on snapd-glib for adding support for exit codes returned by snapctl commands issued via library function (merged)](https://github.com/snapcore/snapd-glib/pull/97)

all: build

build:
	wget https://github.com/apple/cups/releases/download/v2.2.4/cups-2.2.4-source.tar.gz
	tar -xvzf cups-2.2.4-source.tar.gz
	(cd cups-2.2.4; patch -p0 < ../cupsd-pass-on-ld-library-path.patch; ./configure --with-system-groups='sys root'; make)

install:
	(cd cups-2.2.4; make BUILDROOT=$(DESTDIR) install)

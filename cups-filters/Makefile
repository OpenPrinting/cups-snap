all: build
build:
	wget http://www.openprinting.org/download/cups-filters/cups-filters-1.17.8.tar.xz
	tar -xvJf cups-filters-1.17.8.tar.xz
	(cd cups-filters-1.17.8; \
	CPPFLAGS=-I$$SNAPCRAFT_STAGE/usr/include LDFLAGS=-L$$SNAPCRAFT_STAGE/usr/lib ./configure --with-pdftops=mupdf --with-mutool-path=cups.mutool --disable-ghostscript --disable-poppler; \
	make)

install:
	(cd cups-filters-1.17.8; make DESTDIR=$(DESTDIR) install)

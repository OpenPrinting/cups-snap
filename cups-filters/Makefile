all: build
build:
	wget http://www.openprinting.org/download/cups-filters/cups-filters-1.17.9.tar.xz
	tar -xvJf cups-filters-1.17.9.tar.xz
	(cd cups-filters-1.17.9; \
	CPPFLAGS=-I$$SNAPCRAFT_STAGE/usr/include LDFLAGS=-L$$SNAPCRAFT_STAGE/usr/lib ./configure --with-pdftops=pdftops --disable-ghostscript --disable-mutool; \
	make)
	#(cd cups-filters-1.17.9; \
	#CPPFLAGS=-I$$SNAPCRAFT_STAGE/usr/include LDFLAGS=-L$$SNAPCRAFT_STAGE/usr/lib ./configure --with-pdftops=mupdf --with-mutool-path=cups.mutool --disable-ghostscript --disable-poppler; \
	#make)

install:
	(cd cups-filters-1.17.9; make DESTDIR=$(DESTDIR) install)

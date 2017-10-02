all: build

build:
	wget http://mupdf.com/downloads/mupdf-1.11-source.tar.gz
	tar -xvzf mupdf-1.11-source.tar.gz
	(cd mupdf-1.11-source; make prefix=/usr HAVE_X11=no HAVE_GLFW=no)

install:
	(cd mupdf-1.11-source; mkdir -p $(DESTDIR)/usr/bin; cp build/release/mutool $(DESTDIR)/usr/bin)

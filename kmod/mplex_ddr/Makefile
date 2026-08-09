# Build on MiSTer with matching headers:
#   make -C /lib/modules/$(uname -r)/build M=$(pwd) modules
obj-m += mplex_ddr.o
KDIR ?= /lib/modules/$(shell uname -r)/build
all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

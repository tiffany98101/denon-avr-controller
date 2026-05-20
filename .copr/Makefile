# Copr build entry point.
#
# Copr invokes:   make -f .copr/Makefile srpm outdir=<path>
#
# The srpm target must produce a .src.rpm in $(outdir).  We download the
# upstream tarball via spectool (from rpmdevtools) and build the SRPM with
# rpmbuild.  Both packages are present in the Copr build environment.
#
# To test locally:
#   mkdir -p /tmp/copr-out
#   make -f .copr/Makefile srpm outdir=/tmp/copr-out
#   ls /tmp/copr-out/*.src.rpm

SPEC := rpm/denon-avr-controller.spec

.PHONY: srpm

srpm:
	mkdir -p $(outdir)
	spectool -g -C $(outdir) $(SPEC)
	rpmbuild -bs \
		--define "_sourcedir $(outdir)" \
		--define "_srcrpmdir $(outdir)" \
		$(SPEC)

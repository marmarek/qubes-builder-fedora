#!/bin/bash

source "${SCRIPTSDIR}/distribution.sh"

prepareChroot

export YUM0=$PWD/pkgs-for-template

cp ${SCRIPTSDIR}/template-builder-repo.repo ${INSTALLDIR}/etc/yum.repos.d/
if [ -n "$USE_QUBES_REPO_VERSION" ]; then
    sed -e "s/%QUBESVER%/$USE_QUBES_REPO_VERSION/g" \
        < ${SCRIPTSDIR}/../repos/qubes-repo-vm.repo \
        > ${INSTALLDIR}/etc/yum.repos.d/template-qubes-vm.repo
    keypath="${BUILDER_DIR}/qubes-release-${USE_QUBES_REPO_VERSION}-signing-key.asc"
    if [ -r "$keypath" ]; then
        # use stdin to not copy the file into chroot. /dev/stdin
        # symlink doesn't exists there yet
        chroot_cmd rpm --import /proc/self/fd/0 < "$keypath"
    fi
    if [ "0$USE_QUBES_REPO_TESTING" -gt 0 ]; then
        yumConfigRepository enable 'qubes-builder-*-current-testing'
    fi
fi

echo "--> Installing RPMs..."
if [ "$TEMPLATE_FLAVOR" != "minimal" ]; then
    installPackages packages_qubes.list || RETCODE=1
else
    installPackages packages_qubes_minimal.list || RETCODE=1
fi

chroot_cmd sh -c 'rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-qubes-*'

if [ "$TEMPLATE_FLAVOR" != "minimal" ]; then
    echo "--> Installing 3rd party apps"
    $SCRIPTSDIR/add_3rd_party_software.sh || RETCODE=1
fi


if [ "$TEMPLATE_FLAVOR" != "minimal" ]; then
    # this is mostly legacy stuff as newer fedora don't have this file
    if [ -e mnt/etc/sysconfig/i18n ]; then
        echo "--> Setting up default locale..."
        echo LC_CTYPE=en_US.UTF-8 > mnt/etc/sysconfig/i18n
    fi
else
    # for minimal template reset LANG to "C", but only if was set previously
    if grep -q LANG= ${INSTALLDIR}/etc/locale.conf 2>/dev/null; then
        sed -e 's/^LANG=.*/LANG=C/' -i ${INSTALLDIR}/etc/locale.conf
    fi
fi

if [ "0$TEMPLATE_ROOT_WITH_PARTITIONS" -eq 1 ]; then
    # if root.img have partitions, install kernel and grub there
    yumInstall kernel || RETCODE=1
    for kver in $(ls ${INSTALLDIR}/lib/modules); do
        yumInstall kernel-devel-${kver} || RETCODE=1
    done
    yumInstall grub2 qubes-kernel-vm-support || RETCODE=1
    chroot_cmd mount -t sysfs sys /sys
    chroot_cmd mount -t devtmpfs none /dev
    # find the right loop device, _not_ its partition
    dev=$(df --output=source $INSTALLDIR | tail -n 1)
    dev=${dev%p?}
    for kver in $(ls ${INSTALLDIR}/lib/modules); do
        chroot_cmd dkms autoinstall -k "$kver" || RETCODE=1
        chroot_cmd dracut -f -a "qubes-vm qubes-vm-modules" \
            /boot/initramfs-${kver}.img ${kver} || RETCODE=1
    done
    chroot_cmd grub2-install "$dev" || RETCODE=1
    chroot_cmd grub2-mkconfig -o /boot/grub2/grub.cfg || RETCODE=1
    chroot_cmd umount /sys /dev
fi

# Distribution specific steps
source ./functions.sh
buildStep "${0}" "${DIST}"

rm -f ${INSTALLDIR}/etc/yum.repos.d/template-builder-repo.repo
rm -f ${INSTALLDIR}/etc/yum.repos.d/template-qubes-vm.repo

exit $RETCODE

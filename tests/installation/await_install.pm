# SUSE's openQA tests
#
# Copyright © 2009-2013 Bernhard M. Wiedemann
# Copyright © 2012-2020 SUSE LLC
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved.  This file is offered as-is,
# without any warranty.

# Summary: Monitor installation progress and wait for "reboot now" dialog
# - Inside a loop, run check_screen for each element of array @tags
# - Check return code of check_screen against array @tags
#   - If no return code, decreate timeout by 30s, print diagnose text: "left total await_install timeout: $timeout"
#   - If timeout less than 0, assert_screen on element of @tags and abort: "timeout hit on during await_install"
#   'installation not finished, move mouse around a bit to keep screen unlocked'
#   and move mouse to prevent screenlock
#   - If needle matches "yast_error", abort with 'YaST error detected. Test is terminated.'
#   - If needle matches 'yast2_wrong_digest', abort with 'Wrong Digest detected error, need to end test.'
#   - If needle matches 'yast2_package_retry', record_soft_failure 'boo#1018262
#   retry failing packages', send 'alt-y', retry in 4s, otherwise, abort with 'boo#1018262 - seems to be stuck on retry'
#   - If needle matches 'DIALOG-packages-notifications', send alt-o
#   - if needle matches 'ERROR-removing-package':
#     - Send 'alt-d', check for needle 'ERROR-removing-package-details'
#     - Send 'alt-i', check for needle 'WARNING-ignoring-package-failure'
#     - Send 'alt-o'
#   - If LIVECD is defined and needle "screenlock" matches:
#     - Call "handle_livecd_screenlock"
#       - Call record_soft_failure 'boo#994044: Kde-Live net installer is interrupted by screenlock'
#       - Print diag message 'unlocking screenlock with no password in LIVECD mode'
#       - While "screenlock" needle matches:
#         - Send 'alt-tab'
#         - While no "blackscreen" matches:
#           - Send 'tab'
#           - Send 'ret'
#       - Save a screenshot
#       - Check for a needle: "yast-still-running"
#   - If needle matches 'additional-packages'
#     - Send 'alt-i'
#   - If needle matches 'package-update-found'
#     - Send 'alt-n'
#   - Stop reboot timeout where necessary
# Maintainer: Oliver Kurz <okurz@suse.de>

use strict;
use warnings;
use base 'y2_installbase';
use testapi;
use lockapi;
use mmapi;
use utils;
use version_utils qw(:VERSION :BACKEND);
use ipmi_backend_utils;

sub handle_livecd_screenlock {
    record_soft_failure 'boo#994044: Kde-Live net installer is interrupted by screenlock';
    diag('unlocking screenlock with no password in LIVECD mode');
    my $retries = 7;
    for (1 .. $retries) {
        # password and unlock button seem to be not in focus so switch to
        # the only 'window' shown, tab over the empty password field and
        # confirm unlocking
        send_key 'alt-tab';
        if (!match_has_tag('blackscreen')) {
            send_key 'tab';
            send_key 'ret';
        }
        last unless check_screen([qw(screenlock blackscreen)], 20);
        die "Failed to unlock screen within multiple retries" if $_ == $retries;
    }
    save_screenshot;
    # can take a long time until the screen unlock happens as the
    # system is busy installing.
    assert_screen('yast-still-running', 120);
}

# Stop countdown and check success by waiting screen change without performing an action
sub wait_countdown_stop {
    my ($stilltime, $similarity) = @_;
    send_key 'alt-s';
    return wait_screen_change(undef, $stilltime, similarity => $similarity);
}

sub run {
    my $self = shift;
    # NET isos are slow to install
    my $timeout = 2000;

    # workaround for yast popups and
    # detect "Wrong Digest" error to end test earlier
    my @tags = qw(rebootnow yast2_wrong_digest yast2_package_retry yast_error initializing-target-directory-failed);
    if (get_var('UPGRADE') || get_var('LIVE_UPGRADE')) {
        push(@tags, 'ERROR-removing-package');
        push(@tags, 'DIALOG-packages-notifications');
        # There is a dialog with packages that updates are available from
        # the official repo, do not use those as want to use not published repos only
        push(@tags, 'package-update-found') if is_opensuse;
        # upgrades are slower
        $timeout = 5500;
    }
    # our Hyper-V server is just too slow
    # SCC might mean we install everything from the slow internet
    if (check_var('VIRSH_VMM_FAMILY', 'hyperv') || (check_var('SCC_REGISTER', 'installation') && !get_var('SCC_URL'))) {
        $timeout = 5500;
    }
    # VMware server is also a bit slow, needs to take more time
    if (check_var('VIRSH_VMM_FAMILY', 'vmware')) {
        $timeout = 3600;
    }
    # aarch64 can be particularily slow depending on the hardware
    $timeout *= 2 if check_var('ARCH', 'aarch64') && get_var('MAX_JOB_TIME');
    # PPC HMC (Power9) performs very slow in general
    $timeout *= 2 if check_var('BACKEND', 'pvm_hmc') && get_var('MAX_JOB_TIME');
    # encryption, LVM and RAID makes it even slower
    $timeout *= 2 if (get_var('ENCRYPT') || get_var('LVM') || get_var('RAID'));
    # "allpatterns" tests install a lot of packages
    $timeout *= 2 if check_var_array('PATTERNS', 'all');
    # multipath installations seem to take longer (failed some time)
    $timeout *= 2 if check_var('MULTIPATH', 1);
    # Scale timeout
    $timeout *= get_var('TIMEOUT_SCALE', 1);
    # on s390 we might need to install additional packages depending on the installation method
    if (check_var('ARCH', 's390x')) {
        push(@tags, 'additional-packages');
    }
    # For poo#64228, we need ensure the timeout value less than the MAX_JOB_TIME
    my $max_job_time_bound = get_var('MAX_JOB_TIME', 7200) - 1000;
    record_info("Timeout exceeded", "Computed timeout '$timeout' exceeds max_job_time_bound '$max_job_time_bound', consider decreasing '$timeout' or increasing 'MAX_JOB_TIME'") if $timeout > $max_job_time_bound;

    my $mouse_x = 1;
    while (1) {
        die 'timeout hit on during await_install' if $timeout <= 0;
        my $ret = check_screen \@tags, 30;
        $timeout -= 30;
        diag("left total await_install timeout: $timeout");
        if (!$ret) {
            if (get_var('LIVECD') || get_var('SUPPORT_SERVER')) {
                # The workaround with mouse moving was added, because screen
                # become disabled after some time without activity on aarch64.
                # Mouse is moved by 10 pixels, waited for 1 second (this is
                # needed because it seems like the move is too fast to be detected
                # on aarch64).
                diag('installation not finished, move mouse around a bit to keep screen unlocked');
                mouse_set(($mouse_x + 10) % 1024, 1);
                sleep 1;
                mouse_set($mouse_x, 1);
            }
            next;
        }
        if (match_has_tag('yast_error')) {
            die 'YaST error detected. Test is terminated.';
        }

        if (match_has_tag('yast2_wrong_digest')) {
            die 'Wrong Digest detected error, need to end test.';
        }

        if (match_has_tag('yast2_package_retry')) {
            record_soft_failure 'boo#1018262 - retry failing packages';
            send_key 'alt-y';    # retry
            die 'boo#1018262 - seems to be stuck on retry' unless wait_screen_change { sleep 4 };
            next;
        }

        if (match_has_tag('DIALOG-packages-notifications')) {
            send_key 'alt-o';    # ok
            next;
        }
        # can happen multiple times
        if (match_has_tag('ERROR-removing-package')) {
            send_key 'alt-d';    # details
            assert_screen 'ERROR-removing-package-details';
            send_key 'alt-i';    # ignore
            assert_screen 'WARNING-ignoring-package-failure';
            send_key 'alt-o';    # ok
            next;
        }
        if (get_var('LIVECD') and (check_screen('screenlock') || check_screen('blackscreen'))) {
            handle_livecd_screenlock;
            next;
        }
        if (match_has_tag('additional-packages')) {
            send_key 'alt-i';
            next;
        }
        #
        if (match_has_tag 'package-update-found') {
            send_key 'alt-n';
            next;
        }
        # rpm cache failed to load
        if (match_has_tag 'initializing-target-directory-failed') {
            record_soft_failure "bsc#1182928 - Initializing the target directory failed";
            send_key 'alt-o';
            next;
        }
        last;
    }

    if (get_var('USE_SUPPORT_SERVER') && get_var('USE_SUPPORT_SERVER_REPORT_PKGINSTALL')) {
        my $jobid_server = (get_parents())->[0] or die "USE_SUPPORT_SERVER_REPORT_PKGINSTALL set, but no parent supportserver job found";
        # notify the supportserver about current status (e.g.: meddle_multipaths.pm)
        mutex_create("client_pkginstall_done", $jobid_server);
        record_info("Disk I/O", "Mutex \"client_pkginstall_done\" created");
    }

    # Stop reboot countdown where necessary for e.g. uploading logs
    unless (check_var('REBOOT_TIMEOUT', 0) || get_var("REMOTE_CONTROLLER") || is_microos || (is_sle('=11-sp4') && check_var('ARCH', 's390x') && check_var('BACKEND', 's390x'))) {
        # Depending on the used backend the initial key press to stop the
        # countdown might not be evaluated correctly or in time. In these
        # cases we keep hitting the keys until the countdown stops.
        my $counter = 10;
        # A single changing digit is only a minor change, overide default
        # similarity level considered a screen change
        my $minor_change_similarity = 55;
        while ($counter-- and wait_countdown_stop(3, $minor_change_similarity)) {
            record_info('workaround', "While trying to stop countdown we saw a screen change, retrying up to $counter times more");
        }
    }
}

1;

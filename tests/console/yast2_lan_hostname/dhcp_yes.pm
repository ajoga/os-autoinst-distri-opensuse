# SUSE's openQA tests
#
# Copyright © 2021 SUSE LLC
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved.  This file is offered as-is,
# without any warranty.

# Package: yast2-network
# Summary: Verify that correct value is stored in network config when
# setting hostname via DHCP to 'yes: any' in YaST2 lan module (https://bugzilla.suse.com/show_bug.cgi?id=984890)
# Maintainer: QA SLE YaST team <qa-sle-yast@suse.de>

use parent 'yast2_lan_hostname_base';
use strict;
use warnings;
use testapi;
use scheduler qw(get_test_suite_data);
use YaST::Module;

sub run {
    my $test_data = get_test_suite_data();
    YaST::Module::open({module => 'lan', ui => $test_data->{yast2_lan_hostname}->{ui}});
    my $network_settings = $testapi::distri->get_network_settings();
    $network_settings->confirm_warning() if $test_data->{yast2_lan_hostname}->{confirm_warning};
    $network_settings->set_hostname_via_dhcp({dhcp_option => 'yes: any'});
    $network_settings->save_changes();

    assert_screen 'console-visible', 180;
    wait_still_screen;
    assert_script_run 'grep DHCLIENT_SET_HOSTNAME /etc/sysconfig/network/dhcp|grep yes';
}

1;

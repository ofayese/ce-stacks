<?php
/**
 * Minimal phpMyAdmin override config for Docker image.
 * Keep credentials in environment variables.
 */

$i = 1;

$cfg['Servers'][$i]['verbose'] = 'Code Server MySQL';
$cfg['Servers'][$i]['host'] = 'db';
$cfg['Servers'][$i]['port'] = '3306';
$cfg['Servers'][$i]['socket'] = '';
$cfg['Servers'][$i]['connect_type'] = 'tcp';
$cfg['Servers'][$i]['extension'] = 'mysqli';
$cfg['Servers'][$i]['compress'] = false;
$cfg['Servers'][$i]['AllowNoPassword'] = false;

$cfg['Servers'][$i]['controlhost'] = 'db';
$cfg['Servers'][$i]['controlport'] = '3306';
$cfg['Servers'][$i]['controluser'] = getenv('PMA_CONTROLUSER') ?: 'pma';
$cfg['Servers'][$i]['controlpass'] = getenv('PMA_CONTROLPASS') ?: '';

$cfg['Servers'][$i]['auth_type'] = 'cookie';

$cfg['Servers'][$i]['pmadb'] = 'phpmyadmin';
$cfg['Servers'][$i]['bookmarktable'] = 'pma__bookmark';
$cfg['Servers'][$i]['relation'] = 'pma__relation';
$cfg['Servers'][$i]['table_info'] = 'pma__table_info';
$cfg['Servers'][$i]['table_coords'] = 'pma__table_coords';
$cfg['Servers'][$i]['pdf_pages'] = 'pma__pdf_pages';
$cfg['Servers'][$i]['column_info'] = 'pma__column_info';
$cfg['Servers'][$i]['history'] = 'pma__history';
$cfg['Servers'][$i]['table_uiprefs'] = 'pma__table_uiprefs';
$cfg['Servers'][$i]['tracking'] = 'pma__tracking';
$cfg['Servers'][$i]['userconfig'] = 'pma__userconfig';
$cfg['Servers'][$i]['recent'] = 'pma__recent';
$cfg['Servers'][$i]['favorite'] = 'pma__favorite';
$cfg['Servers'][$i]['users'] = 'pma__users';
$cfg['Servers'][$i]['usergroups'] = 'pma__usergroups';
$cfg['Servers'][$i]['navigationhiding'] = 'pma__navigationhiding';
$cfg['Servers'][$i]['savedsearches'] = 'pma__savedsearches';
$cfg['Servers'][$i]['central_columns'] = 'pma__central_columns';
$cfg['Servers'][$i]['designer_settings'] = 'pma__designer_settings';
$cfg['Servers'][$i]['export_templates'] = 'pma__export_templates';

$cfg['blowfish_secret'] = getenv('PMA_BLOWFISH_SECRET') ?: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
$cfg['PmaAbsoluteUri'] = getenv('PMA_ABSOLUTE_URI') ?: '';
$cfg['AllowArbitraryServer'] = false;
$cfg['ShowPhpInfo'] = false;
$cfg['AllowUserDropDatabase'] = false;
$cfg['DefaultLang'] = 'en';

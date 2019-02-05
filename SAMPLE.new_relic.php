<?php
/**
 * Plugin Name: New Relic
 * Plugin URI:  http://mediebruket.no/
 * Description: Initializes New Relic monitoring if installed.
 * Version:     0.2
 * Author:      Håvard Grimelid
 * Author URI:  http://mediebruket.no/
 * License:     MIT
 */

// Prevent loading this file directly
defined( 'ABSPATH' ) OR exit;

add_action('init', 'init_new_relic');

function init_new_relic() {

  $app_name = DB_NAME;

  if ( ! ( extension_loaded ('newrelic') && function_exists('newrelic_set_appname') ) ) return;

  // is_admin() will return false when trying to access wp-login.php.
  // is_admin() will return true when trying to make an ajax request.
  // is_admin() will return true for calls to load-scripts.php and load-styles.php.
  if ( is_admin() ) {
    if ( defined( 'DOING_AJAX' ) && DOING_AJAX ) {
      newrelic_set_appname( $app_name . ' ajax' );
    }
    else {
      newrelic_set_appname( $app_name . ' admin' );
    }
  }
  elseif ( defined( 'DOING_CRON' ) && DOING_CRON ) {
    newrelic_set_appname( $app_name . ' cron' );
  }
  else {
    newrelic_set_appname( $app_name . ' frontend');
  }
}

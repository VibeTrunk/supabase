[CmdletBinding()]
param(
  [string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

$catalogueDirectory = Join-Path $RepoRoot "supabase\migrations"
$parentDirectory = Split-Path -Parent $RepoRoot
$expectedSources = @(
  @{ File = "202608160001_cogitster_solo.sql"; Source = Join-Path $parentDirectory "cogitster\supabase\migrations\202608160001_cogitster_solo.sql" },
  @{ File = "20260816000000_create_kut_schema.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260816000000_create_kut_schema.sql" },
  @{ File = "20260816010000_phase_1a_roster_and_ratings.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260816010000_phase_1a_roster_and_ratings.sql" },
  @{ File = "20260816020000_publish_and_rebuild_sessions.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260816020000_publish_and_rebuild_sessions.sql" },
  @{ File = "20260816030000_publish_attendance_session.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260816030000_publish_attendance_session.sql" },
  @{ File = "20260816040000_public_live_ratings_view.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260816040000_public_live_ratings_view.sql" },
  @{ File = "20260816050000_invite_onboarding.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260816050000_invite_onboarding.sql" },
  @{ File = "20260816050100_preserve_consumed_invite_audit.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260816050100_preserve_consumed_invite_audit.sql" },
  @{ File = "20260816060000_correct_published_sessions.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260816060000_correct_published_sessions.sql" },
  @{ File = "20260816060100_grant_session_correction_reads.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260816060100_grant_session_correction_reads.sql" },
  @{ File = "20260816060200_cancel_published_sessions.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260816060200_cancel_published_sessions.sql" },
  @{ File = "20260816060300_reversible_session_lifecycle.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260816060300_reversible_session_lifecycle.sql" },
  @{ File = "20260816070000_wallet_starter_and_attendance_rewards.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260816070000_wallet_starter_and_attendance_rewards.sql" },
  @{ File = "20260816070100_audited_admin_password_resets.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260816070100_audited_admin_password_resets.sql" },
  @{ File = "20260816070200_collection_read_projection.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260816070200_collection_read_projection.sql" },
  @{ File = "20260816070300_server_authoritative_card_discard.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260816070300_server_authoritative_card_discard.sql" },
  @{ File = "20260816070400_atomic_basic_pack_opening.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260816070400_atomic_basic_pack_opening.sql" },
  @{ File = "20260816070500_pack_economy_health.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260816070500_pack_economy_health.sql" },
  @{ File = "20260816070600_atomic_marketplace.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260816070600_atomic_marketplace.sql" },
  @{ File = "20260816070601_fix_market_wallet_lock.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260816070601_fix_market_wallet_lock.sql" },
  @{ File = "20260817000000_expose_market_seller_name.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260817000000_expose_market_seller_name.sql" },
  @{ File = "20260817010000_club_value_leaderboard.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260817010000_club_value_leaderboard.sql" },
  @{ File = "20260817010001_fix_club_value_projection_permissions.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260817010001_fix_club_value_projection_permissions.sql" },
  @{ File = "20260817020000_message_center_market_notifications.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260817020000_message_center_market_notifications.sql" },
  @{ File = "20260817020100_include_buyer_in_sale_notifications.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260817020100_include_buyer_in_sale_notifications.sql" },
  @{ File = "20260817030000_private_live_ratings.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260817030000_private_live_ratings.sql" },
  @{ File = "20260818000000_initial_tfh_roster_and_august_sessions.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260818000000_initial_tfh_roster_and_august_sessions.sql" },
  @{ File = "20260829000000_august_2026_full_month_roster_and_sessions.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260829000000_august_2026_full_month_roster_and_sessions.sql" },
  @{ File = "20260829120000_admin_add_player.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260829120000_admin_add_player.sql" },
  @{ File = "20260829130000_admin_manage_roster.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260829130000_admin_manage_roster.sql" },
  @{ File = "20260830000000_member_self_service_and_player_directory.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260830000000_member_self_service_and_player_directory.sql" },
  @{ File = "20260831000000_admin_links_username_and_attendance_messages.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260831000000_admin_links_username_and_attendance_messages.sql" },
  @{ File = "20260901000000_admin_manage_accounts_and_leaderboard.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260901000000_admin_manage_accounts_and_leaderboard.sql" },
  @{ File = "20260902000000_starter_reveal_and_rating_snapshots.sql"; Source = Join-Path $parentDirectory "kut\supabase\migrations\20260902000000_starter_reveal_and_rating_snapshots.sql" }
)

foreach ($entry in $expectedSources) {
  $cataloguePath = Join-Path $catalogueDirectory $entry.File
  if (-not (Test-Path -LiteralPath $cataloguePath) -or -not (Test-Path -LiteralPath $entry.Source)) {
    throw "Missing migration source: $($entry.File)"
  }
  $catalogueHash = (Get-FileHash -LiteralPath $cataloguePath -Algorithm SHA256).Hash
  $sourceHash = (Get-FileHash -LiteralPath $entry.Source -Algorithm SHA256).Hash
  if ($catalogueHash -ne $sourceHash) {
    throw "Migration drift detected: $($entry.File)"
  }
}

Write-Output "Central catalogue matches $($expectedSources.Count) approved source migrations."

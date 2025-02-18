#!/bin/bash

# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eu

# Integration tests for bundling simple iOS applications.

function set_up() {
  mkdir -p app
}

function tear_down() {
  rm -rf app
}

# Creates common source, targets, and basic plist for iOS applications.
function create_common_files() {
  cat > app/BUILD <<EOF
load("@build_bazel_rules_apple//apple:ios.bzl",
     "ios_application"
    )
load("@build_bazel_rules_apple//apple:apple.bzl",
     "apple_dynamic_framework_import",
     "apple_static_framework_import",
    )
load("@build_bazel_rules_apple//apple:resources.bzl",
     "apple_resource_bundle",
    )

objc_library(
    name = "lib",
    srcs = ["main.m"],
)
EOF

  cat > app/main.m <<EOF
int main(int argc, char **argv) {
  return 0;
}
EOF

  cat > app/Info.plist <<EOF
{
  CFBundleIdentifier = "\${PRODUCT_BUNDLE_IDENTIFIER}";
  CFBundleName = "\${PRODUCT_NAME}";
  CFBundlePackageType = "APPL";
  CFBundleVersion = "1.0.0";
  CFBundleShortVersionString = "1.0";
}
EOF
}

# Usage: create_minimal_ios_application [product type]
#
# Creates a minimal iOS application target. The optional product type is
# the Skylark constant that should be set on the application using the
# `product_type` attribute.
function create_minimal_ios_application() {
  if [[ ! -f app/BUILD ]]; then
    fail "create_common_files must be called first."
  fi

  product_type="${1:-}"

  cat >> app/BUILD <<EOF
ios_application(
    name = "app",
    bundle_id = "my.bundle.id",
    families = ["iphone"],
    infoplists = ["Info.plist"],
    minimum_os_version = "9.0",
EOF

  if [[ -n "$product_type" ]]; then
  cat >> app/BUILD <<EOF
    product_type = $product_type,
EOF
  fi

  cat >> app/BUILD <<EOF
    provisioning_profile = "@build_bazel_rules_apple//test/testdata/provisioning:integration_testing_ios.mobileprovision",
    deps = [":lib"],
)
EOF
}

# Creates a minimal iOS application target that depends on an imported
# framework.
#
# This function takes a required parameter denoting whether the framework is
# static or dynamic (corresponding to the framework's is_dynamic attribute).
function create_minimal_ios_application_with_framework_import() {
  readonly framework_type="$1"
  readonly import_rule="$2"

  cat >> app/BUILD <<EOF
ios_application(
    name = "app",
    bundle_id = "my.bundle.id",
    families = ["iphone"],
    infoplists = ["Info.plist"],
    minimum_os_version = "9.0",
    provisioning_profile = "@build_bazel_rules_apple//test/testdata/provisioning:integration_testing_ios.mobileprovision",
    deps = [
        ":frameworkDependingLib",
        ":lib",
    ],
)

objc_library(
    name = "frameworkDependingLib",
    srcs = ["@bazel_tools//tools/objc:dummy.c"],
    deps = [":fmwk"],
)

$import_rule(
    name = "fmwk",
    framework_imports = glob(["fmwk.framework/**"]),
)
EOF

  mkdir -p app/fmwk.framework
  if [[ $framework_type == dynamic ]]; then
    cp $(rlocation build_bazel_rules_apple/test/testdata/binaries/empty_dylib_lipobin) \
        app/fmwk.framework/fmwk
  else
    cp $(rlocation build_bazel_rules_apple/test/testdata/binaries/empty_staticlib_lipo.a) \
        app/fmwk.framework/fmwk
  fi

  cat > app/fmwk.framework/Info.plist <<EOF
Dummy plist
EOF

  cat > app/fmwk.framework/resource.txt <<EOF
Dummy resource
EOF

  mkdir -p app/fmwk.framework/fmwk.bundle
  cat > app/fmwk.framework/fmwk.bundle/Some.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Foo</key>
    <string>Bar</string>
  </dict>
</plist>
EOF

  mkdir -p app/fmwk.framework/Headers
  cat > app/fmwk.framework/Headers/fmwk.h <<EOF
This shouldn't get included
EOF

  mkdir -p app/fmwk.framework/Modules
  cat > app/fmwk.framework/Headers/module.modulemap <<EOF
This shouldn't get included
EOF
}

# Test missing the CFBundleVersion fails the build.
function test_missing_version_fails() {
  create_common_files
  create_minimal_ios_application

  # Replace the file, but without CFBundleVersion.
  cat > app/Info.plist <<EOF
{
  CFBundleIdentifier = "\${PRODUCT_BUNDLE_IDENTIFIER}";
  CFBundleName = "\${PRODUCT_NAME}";
  CFBundlePackageType = "APPL";
  CFBundleShortVersionString = "1.0";
}
EOF

  ! do_build ios //app:app \
    || fail "Should fail build"

  expect_log 'Target "//app:app" is missing CFBundleVersion.'
}

# Test missing the CFBundleShortVersionString fails the build.
function test_missing_short_version_fails() {
  create_common_files
  create_minimal_ios_application

  # Replace the file, but without CFBundleShortVersionString.
  cat > app/Info.plist <<EOF
{
  CFBundleIdentifier = "\${PRODUCT_BUNDLE_IDENTIFIER}";
  CFBundleName = "\${PRODUCT_NAME}";
  CFBundlePackageType = "APPL";
  CFBundleVersion = "1.0.0";
}
EOF

  ! do_build ios //app:app \
    || fail "Should fail build"

  expect_log 'Target "//app:app" is missing CFBundleShortVersionString.'
}

# Tests that the linkmap outputs are produced when --objc_generate_linkmap is
# present.
function disabled_test_linkmaps_generated() {  # Blocked on b/73547215
  create_common_files
  create_minimal_ios_application
  do_build ios --objc_generate_linkmap //app:app || fail "Should build"

  declare -a archs=( $(current_archs ios) )
  for arch in "${archs[@]}"; do
    assert_exists "test-bin/app/app_${arch}.linkmap"
  done
}

# Tests that the provisioning profile is present when built for device.
function test_contains_provisioning_profile() {
  # Ignore the test for simulator builds.
  is_device_build ios || return 0

  create_common_files
  create_minimal_ios_application
  do_build ios //app:app || fail "Should build"

  # Verify that the IPA contains the provisioning profile.
  assert_zip_contains "test-bin/app/app.ipa" \
      "Payload/app.app/embedded.mobileprovision"
}

# Tests that the IPA post-processor is executed and can modify the bundle.
function test_ipa_post_processor() {
  create_common_files

  cat >> app/BUILD <<EOF
ios_application(
    name = "app",
    bundle_id = "my.bundle.id",
    families = ["iphone"],
    infoplists = ["Info.plist"],
    ipa_post_processor = "post_processor.sh",
    minimum_os_version = "9.0",
    provisioning_profile = "@build_bazel_rules_apple//test/testdata/provisioning:integration_testing_ios.mobileprovision",
    deps = [":lib"],
)
EOF

  cat > app/post_processor.sh <<EOF
#!/bin/bash
WORKDIR="\$1"
echo "foo" > "\$WORKDIR/Payload/app.app/inserted_by_post_processor.txt"
EOF
  chmod +x app/post_processor.sh

  do_build ios //app:app || fail "Should build"
  assert_equals "foo" "$(unzip_single_file "test-bin/app/app.ipa" \
      "Payload/app.app/inserted_by_post_processor.txt")"
}

# Tests that linkopts get passed to the underlying apple_binary target.
function test_linkopts_passed_to_binary() {
  # Bail out early if this is a Bitcode build; the -alias flag we use to test
  # this isn't compatible with Bitcode. That's ok; as long as the test passes
  # for non-Bitcode builds, we're good.
  is_bitcode_build && return 0

  create_common_files

  cat >> app/BUILD <<EOF
ios_application(
    name = "app",
    bundle_id = "my.bundle.id",
    families = ["iphone"],
    infoplists = ["Info.plist"],
    linkopts = ["-alias", "_main", "_linkopts_test_main"],
    minimum_os_version = "9.0",
    provisioning_profile = "@build_bazel_rules_apple//test/testdata/provisioning:integration_testing_ios.mobileprovision",
    deps = [":lib"],
)
EOF

  do_build ios //app:app || fail "Should build"

  unzip_single_file "test-bin/app/app.ipa" "Payload/app.app/app" |
      nm -j - | grep _linkopts_test_main  > /dev/null \
      || fail "Could not find -alias symbol in binary; " \
              "linkopts may have not propagated"
}

# Tests that the PkgInfo file exists in the bundle and has the expected
# content.
function test_pkginfo_contents() {
  create_common_files
  create_minimal_ios_application
  do_build ios //app:app || fail "Should build"

  assert_equals "APPL????" "$(unzip_single_file "test-bin/app/app.ipa" \
      "Payload/app.app/PkgInfo")"
}

# Helper to test different values if a build adds the debugger entitlement.
# First arg is "y|n" for if it was expected for device builds
# Second arg is "y|n" for if it was expected for simulator builds.
# Any other args are passed to `do_build`.
function verify_debugger_entitlements_with_params() {
  readonly FOR_DEVICE=$1; shift
  readonly FOR_SIM=$1; shift

  create_common_files

  cat >> app/BUILD <<EOF
ios_application(
    name = "app",
    bundle_id = "my.bundle.id",
    entitlements = "entitlements.plist",
    families = ["iphone"],
    infoplists = ["Info.plist"],
    minimum_os_version = "9.0",
    provisioning_profile = "@build_bazel_rules_apple//test/testdata/provisioning:integration_testing_ios.mobileprovision",
    deps = [":lib"],
)
EOF

  # Use a local entitlements file so the default isn't extracted from the
  # provisioning profile (which likely has get-task-allow).
  cat > app/entitlements.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>keychain-access-groups</key>
  <array>
    <string>\$(AppIdentifierPrefix)\$(CFBundleIdentifier)</string>
  </array>
</dict>
</plist>
EOF

  if is_device_build ios ; then
    # For device builds, entitlements are in the codesign output.
    create_dump_codesign "//app:app" "Payload/app.app" -d --entitlements :-
    do_build ios "$@" //app:dump_codesign || fail "Should build"

    readonly FILE_TO_CHECK="test-genfiles/app/codesign_output"
    readonly SHOULD_CONTAIN="${FOR_DEVICE}"
  else
    # For simulator builds, entitlements are added as a Mach-O section in
    # the binary.
    do_build ios "$@" //app:app || fail "Should build"
    unzip_single_file "test-bin/app/app.ipa" "Payload/app.app/app" | \
        print_debug_entitlements - > "${TEST_TMPDIR}/dumped_entitlements"

    readonly FILE_TO_CHECK="${TEST_TMPDIR}/dumped_entitlements"
    readonly SHOULD_CONTAIN="${FOR_SIM}"
  fi

  if [[ "${SHOULD_CONTAIN}" == "y" ]] ; then
    assert_contains "<key>get-task-allow</key>" "${FILE_TO_CHECK}"
  else
    assert_not_contains "<key>get-task-allow</key>" "${FILE_TO_CHECK}"
  fi
}

# Tests that debugger entitlements are auto-added to the application correctly.
function test_debugger_entitlements_default() {
  # For default builds, configuration.bzl also forces -c opt, so there will be
  #   no debug entitlements.
  verify_debugger_entitlements_with_params n n
}

# Test the different values for apple.add_debugger_entitlement.
function test_debugger_entitlements_forced_false() {
  verify_debugger_entitlements_with_params n n \
      --define=apple.add_debugger_entitlement=false
}
function test_debugger_entitlements_forced_no() {
  verify_debugger_entitlements_with_params n n \
      --define=apple.add_debugger_entitlement=no
}
function test_debugger_entitlements_forced_yes() {
  verify_debugger_entitlements_with_params y y \
      --define=apple.add_debugger_entitlement=YES
}
function test_debugger_entitlements_forced_true() {
  verify_debugger_entitlements_with_params y y \
      --define=apple.add_debugger_entitlement=True
}

# Tests that the target name is sanitized before it is used as the symbol name
# for embedded debug entitlements.
function test_target_name_sanitized_for_entitlements() {
  create_common_files

  cat >> app/BUILD <<EOF
ios_application(
    name = "app-with-hyphen",
    bundle_id = "my.bundle.id",
    entitlements = "entitlements.plist",
    families = ["iphone"],
    infoplists = ["Info.plist"],
    minimum_os_version = "9.0",
    provisioning_profile = "@build_bazel_rules_apple//test/testdata/provisioning:integration_testing_ios.mobileprovision",
    deps = [":lib"],
)
EOF

  cat > app/entitlements.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>test-an-entitlement</key>
  <false/>
</dict>
</plist>
EOF

  if ! is_device_build ios ; then
    do_build ios //app:app-with-hyphen || fail "Should build"

    unzip_single_file "test-bin/app/app-with-hyphen.ipa" \
        "Payload/app-with-hyphen.app/app-with-hyphen" | \
        print_debug_entitlements - | \
        grep -sq "<key>test-an-entitlement</key>" || \
        fail "Failed to find custom entitlement"
  fi
}

# Tests that failures to extract from a provisioning profile are propertly
# reported.
function test_provisioning_profile_extraction_failure() {
  create_common_files

  cat >> app/BUILD <<EOF
ios_application(
    name = "app",
    bundle_id = "my.bundle.id",
    families = ["iphone"],
    infoplists = ["Info.plist"],
    minimum_os_version = "9.0",
    provisioning_profile = "bogus.mobileprovision",
    deps = [":lib"],
)
EOF

  cat > app/bogus.mobileprovision <<EOF
BOGUS BOGUS BOGUS BOGUS BOGUS BOGUS BOGUS BOGUS BOGUS BOGUS BOGUS BOGUS BOGUS
EOF

  ! do_build ios //app:app || fail "Should fail"
  # The fact that multiple things are tried is left as an impl detail and
  # only the final message is looked for.
  expect_log 'While processing target "//app:app_entitlements", failed to extract from the provisioning profile "app/bogus.mobileprovision".'
}

# Tests that applications can transitively depend on apple_resource_bundle, and
# that the bundle library resources for the appropriate architecture are
# used in a multi-arch build.
function test_bundle_library_dependency() {
  create_common_files

  cat >> app/BUILD <<EOF
ios_application(
    name = "app",
    bundle_id = "my.bundle.id",
    families = ["iphone"],
    infoplists = ["Info.plist"],
    minimum_os_version = "9.0",
    provisioning_profile = "@build_bazel_rules_apple//test/testdata/provisioning:integration_testing_ios.mobileprovision",
    deps = [
        ":lib",
        ":resLib",
    ],
)

objc_library(
    name = "resLib",
    srcs = ["@bazel_tools//tools/objc:dummy.c"],
    data = [":appResources"],
)

apple_resource_bundle(
    name = "appResources",
    resources = select({
        "@build_bazel_rules_apple//apple:ios_x86_64": ["foo_sim.txt"],
        "@build_bazel_rules_apple//apple:ios_i386": ["foo_sim.txt"],
        "@build_bazel_rules_apple//apple:ios_armv7": ["foo_device.txt"],
        "@build_bazel_rules_apple//apple:ios_arm64": ["foo_device.txt"],
    }),
)
EOF

  cat > app/foo_sim.txt <<EOF
foo_sim
EOF
  cat > app/foo_device.txt <<EOF
foo_device
EOF

  do_build ios //app:app || fail "Should build"

  if is_device_build ios ; then
    assert_zip_contains "test-bin/app/app.ipa" \
        "Payload/app.app/appResources.bundle/foo_device.txt"
  else
    assert_zip_contains "test-bin/app/app.ipa" \
        "Payload/app.app/appResources.bundle/foo_sim.txt"
  fi
}

# Tests that a prebuilt static framework (i.e., apple_static_framework_import)
# is not bundled with the application.
function test_prebuilt_static_apple_framework_import_dependency() {
  create_common_files
  create_minimal_ios_application_with_framework_import static apple_static_framework_import

  do_build ios //app:app || fail "Should build"

  # Verify that it's not bundled.
  assert_zip_not_contains "test-bin/app/app.ipa" \
      "Payload/app.app/Frameworks/fmwk.framework/fmwk"
  assert_zip_not_contains "test-bin/app/app.ipa" \
      "Payload/app.app/Frameworks/fmwk.framework/Info.plist"
  assert_zip_not_contains "test-bin/app/app.ipa" \
      "Payload/app.app/Frameworks/fmwk.framework/resource.txt"
  assert_zip_not_contains "test-bin/app/app.ipa" \
      "Payload/app.app/Frameworks/fmwk.framework/Headers/fmwk.h"
  assert_zip_not_contains "test-bin/app/app.ipa" \
      "Payload/app.app/Frameworks/fmwk.framework/Modules/module.modulemap"
}

# Tests that the resources in the bundle of the static framework are copied to
# the final ipa, and that they are not re-processed
function test_prebuilt_static_apple_static_framework_import_resources() {
  create_common_files
  create_minimal_ios_application_with_framework_import static apple_static_framework_import

  do_build ios //app:app || fail "Should build"

  # Verify that it's not converted to binary.
  assert_plist_is_text "test-bin/app/app.ipa" \
      "Payload/app.app/fmwk.bundle/Some.plist"
}

# Tests that a prebuilt dynamic framework (i.e., apple_dynamic_framework_import)
# is bundled properly with the application.
function test_prebuilt_dynamic_apple_framework_import_dependency() {
  create_common_files
  create_minimal_ios_application_with_framework_import dynamic apple_dynamic_framework_import

  do_build ios //app:app || fail "Should build"

  # Verify that the binary, plist, and resources are included.
  assert_zip_contains "test-bin/app/app.ipa" \
      "Payload/app.app/Frameworks/fmwk.framework/fmwk"
  assert_zip_contains "test-bin/app/app.ipa" \
      "Payload/app.app/Frameworks/fmwk.framework/Info.plist"
  assert_zip_contains "test-bin/app/app.ipa" \
      "Payload/app.app/Frameworks/fmwk.framework/resource.txt"

  # Verify that Headers and Modules directories are excluded.
  assert_zip_not_contains "test-bin/app/app.ipa" \
      "Payload/app.app/Frameworks/fmwk.framework/Headers/fmwk.h"
  assert_zip_not_contains "test-bin/app/app.ipa" \
      "Payload/app.app/Frameworks/fmwk.framework/Modules/module.modulemap"
}

# Helper for empty segment build id failures.
function verify_build_fails_bundle_id_empty_segment_with_param() {
  bundle_id_to_test="$1"; shift

  create_common_files

  cat >> app/BUILD <<EOF
ios_application(
    name = "app",
    bundle_id = "${bundle_id_to_test}",
    families = ["iphone"],
    infoplists = ["Info.plist"],
    minimum_os_version = "9.0",
    deps = [":lib"],
)
EOF

  ! do_build ios //app:app || fail "Should fail"
  expect_log "Empty segment in bundle_id: \"${bundle_id_to_test}\""
}

# Test that invalid bundle ids fail a build.

function test_build_fails_if_bundle_id_empty() {
  verify_build_fails_bundle_id_empty_segment_with_param ""
}

function test_build_fails_if_bundle_id_just_dot() {
  verify_build_fails_bundle_id_empty_segment_with_param "."
}

function test_build_fails_if_bundle_id_leading_dot() {
  verify_build_fails_bundle_id_empty_segment_with_param ".my.bundle.id"
}

function test_build_fails_if_bundle_id_trailing_dot() {
  verify_build_fails_bundle_id_empty_segment_with_param "my.bundle.id."
}

function test_build_fails_if_bundle_id_double_dot() {
  verify_build_fails_bundle_id_empty_segment_with_param "my..bundle.id"
}

function test_build_fails_if_bundle_id_has_invalid_character() {
  create_common_files

  cat >> app/BUILD <<EOF
ios_application(
    name = "app",
    bundle_id = "my#bundle",
    families = ["iphone"],
    infoplists = ["Info.plist"],
    minimum_os_version = "9.0",
    deps = [":lib"],
)
EOF

  ! do_build ios //app:app || fail "Should fail"
  expect_log "Invalid character(s) in bundle_id: \"my#bundle\""
}

# Tests that the IPA contains bitcode symbols when bitcode is embedded.
function disabled_test_bitcode_symbol_maps_packaging() {  # Blocked on b/73546952
  # Bitcode is only availabe on device. Ignore the test for simulator builds.
  is_device_build ios || return 0

  create_common_files
  create_minimal_ios_application

  do_build ios -s --apple_bitcode=embedded \
       //app:app || fail "Should build"

  assert_ipa_contains_bitcode_maps ios "test-bin/app/app.ipa" \
      "Payload/app.app/app"
}

# Tests that the bundle name can be overridden to differ from the target name.
function test_bundle_name_can_differ_from_target() {
  create_common_files

  cat >> app/BUILD <<EOF
ios_application(
    name = "app",
    bundle_id = "my.bundle.id",
    bundle_name = "different",
    families = ["iphone"],
    infoplists = ["Info.plist"],
    minimum_os_version = "9.0",
    provisioning_profile = "@build_bazel_rules_apple//test/testdata/provisioning:integration_testing_ios.mobileprovision",
    deps = [":lib"],
)
EOF

  do_build ios //app:app || fail "Should build"

  # Both the bundle name and the executable name should correspond to
  # bundle_name.
  assert_zip_contains "test-bin/app/app.ipa" "Payload/different.app/"
  assert_zip_contains "test-bin/app/app.ipa" "Payload/different.app/different"
}

# Tests that the label passed to the version attribute overwrites the version
# information already in the plist without error.
function test_version_attr_overrides_plist_contents() {
  create_common_files

  cat >> app/BUILD <<EOF
load("@build_bazel_rules_apple//apple:versioning.bzl",
     "apple_bundle_version",
    )

ios_application(
    name = "app",
    bundle_id = "my.bundle.id",
    families = ["iphone"],
    infoplists = ["Info.plist"],
    minimum_os_version = "9.0",
    provisioning_profile = "@build_bazel_rules_apple//test/testdata/provisioning:integration_testing_ios.mobileprovision",
    version = ":app_version",
    deps = [":lib"],
)

apple_bundle_version(
    name = "app_version",
    build_version = "9.8.7",
    short_version_string = "6.5",
)
EOF

  create_dump_plist "//app:app" "Payload/app.app/Info.plist" \
      CFBundleVersion \
      CFBundleShortVersionString
  do_build ios //app:dump_plist || fail "Should build"

  assert_equals "9.8.7" "$(cat "test-genfiles/app/CFBundleVersion")"
  assert_equals "6.5" "$(cat "test-genfiles/app/CFBundleShortVersionString")"
}

# Tests tree artifacts builds and disable codesigning for simulator play along.
function test_tree_artifacts_and_disable_simulator_codesigning() {
  create_common_files
  create_minimal_ios_application
  do_build ios //app:app \
      --define=apple.experimental.tree_artifact_outputs=yes \
      --define=apple.codesign_simulator_bundles=no || fail "Should build"
}

run_suite "ios_application bundling tests"

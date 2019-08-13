# Copyright 2019 The Bazel Authors. All rights reserved.
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

"Starlark test for testing the outputs of analysis phase."

load(
    "@bazel_skylib//lib:unittest.bzl",
    "analysistest",
    "asserts",
)
load(
    "@bazel_skylib//lib:new_sets.bzl",
    "sets",
)

def _analysis_actions_outputs_test_impl(ctx):
    env = analysistest.begin(ctx)
    expected_outputs = sets.make(ctx.attr.expected_outputs)
    unexpected_outputs = sets.make(ctx.attr.unexpected_outputs)
    all_outputs = sets.make()
    for action in analysistest.target_actions(env):
        for output in action.outputs:
            sets.insert(all_outputs, output.basename)

    # Test that the expected outputs are contained within all outputs
    asserts.new_set_equals(env, expected_outputs, sets.intersection(all_outputs, expected_outputs))

    # Test that the unexpected outputs are not contained within all outputs
    asserts.new_set_equals(env, sets.make(), sets.intersection(all_outputs, unexpected_outputs))

    return analysistest.end(env)

analysis_actions_outputs_test = analysistest.make(
    _analysis_actions_outputs_test_impl,
    attrs = {
        "expected_outputs": attr.string_list(
            doc = "The outputs that are expected.",
            default = [],
        ),
        "unexpected_outputs": attr.string_list(
            doc = "The outputs that are unexpected.",
            default = [],
        ),
    },
)

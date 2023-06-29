"""Implements rules and macros to generate shim templates.
"""

def _shim_transition_impl(settings, attr):
    configurations = {
        target.name: {"//command_line_option:platforms": str(target)}
        for target in attr.targets
    }

    if len(configurations) != len(attr.targets):
        fail("Duplicate name among targets: '{}'".format(
            ", ".join([str(target.label) for target in attr.targets]),
        ))

    return configurations

_shim_transition = transition(
    implementation = _shim_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:platforms",
    ],
)

def _configure_shrink_shims_impl(ctx):
    templates = []
    template_prefix = ctx.attr.shim_prefix
    payload_section = ctx.attr.section_name

    for target, shim in ctx.split_attr.shim.items():
        shim_exe = shim.files_to_run.executable
        template = ctx.actions.declare_file(template_prefix + target)
        ctx.actions.run(
            outputs = [template],
            inputs = [shim_exe],
            executable = ctx.executable.shrink,
            arguments = [shim_exe.path, template.path, payload_section],
            mnemonic = "ShrinkShimTemplate",
            progress_message = "Shrink shim template %{output}",
        )
        templates.append(template)

    zig_content = """\
const std = @import("std");
pub const shim_templates = std.ComptimeStringMap([]const u8, .{
"""
    for target in ctx.split_attr.shim.keys():
        zig_content += (
            '    .{ "' + target +
            '", @embedFile("' + template_prefix + target + '") },\n'
        )

    zig_content += """\
});
"""
    ctx.actions.write(
        output = ctx.outputs.zig_out,
        content = zig_content,
        is_executable = False,
    )

    return [DefaultInfo(files = depset(templates))]

configure_shrink_shims = rule(
    _configure_shrink_shims_impl,
    attrs = {
        "shim": attr.label(
            cfg = _shim_transition,
            # TODO[AH] Raise Bazel issue on 1:2+ transition with cfg = "exec".
            #   This triggers a Bazel crash.
            #   Link to https://github.com/bazelbuild/intellij/issues/824
            doc = "The shim binary.",
            mandatory = True,
        ),
        "shrink": attr.label(
            cfg = "exec",
            executable = True,
            doc = "The tool to shrink the shim binary to shim template.",
            mandatory = True,
        ),
        "section_name": attr.string(
            doc = "The target ELF section from which to strip the shim binary.",
            mandatory = True,
        ),
        "targets": attr.label_list(
            doc = "The target platforms to generate shim templates for. The order must match `templates_out`.",
            mandatory = True,
        ),
        "shim_prefix": attr.string(
            doc = "Prefix for the generated shim template files.",
            mandatory = True,
        ),
        "zig_out": attr.output(
            doc = "The Zig source file to generate.",
            mandatory = True,
        ),
        "_whitelist_function_transition": attr.label(
            default = "@bazel_tools//tools/whitelists/function_transition_whitelist",
        ),
    },
    doc = "Generate shim templates for the requested platforms and a Zig source file embedding all these templates.",
)

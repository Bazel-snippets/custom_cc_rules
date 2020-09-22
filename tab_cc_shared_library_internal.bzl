# Modelled after https://github.com/bazelbuild/bazel/blob/master/src/test/shell/bazel/cc_api_rules.bzl
# Another (older) variant is here: https://github.com/bazelbuild/rules_cc/blob/master/examples/my_c_archive/my_c_compile.bzl

# buildifier: disable=module-docstring
load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load("@bazel_skylib//lib:paths.bzl", "paths") 
load("@tab_toolchains//cc:tab_cc_link_internal.bzl", "link")
load("@tab_toolchains//cc:tab_cc_helpers_internal.bzl", "deduplicate_linker_inputs", "filter_empty_linker_inputs", "filter_static_libs_from_linker_inputs", "filter_attributes")
load("@tab_toolchains//bazel/toolchains:runtime_libs.bzl", "runtime_static_library_files", "runtime_shared_library_files")
load("@tab_toolchains//cc:helpers/tab_cc_shared_library_macro.bzl", "tab_cc_shared_library_macro")
load("@tab_toolchains//helpers:attribute_manipulations.bzl", "location", "add_to_list_attribute")
load("@tab_toolchains//bazel/rules:debug.bzl", "describe") # Debugging

# buildifier: disable=function-docstring
def decorate_name(undecorated_name, output_type, platform):
    if output_type == "executable":
        if   platform == 'windows': decorated_name = undecorated_name + '.exe'
        elif platform == 'linux': decorated_name = undecorated_name
        elif platform == 'osx': decorated_name = undecorated_name
        elif platform == 'asmjs': fail('Building executables for asmjs is not yet supported.')
        else: fail('Unexpected platform %s. Expected values are "windows", "linux", "osx", "asmjs".' % platform)
    elif output_type == "dynamic_library":
        if   platform == 'windows': decorated_name = undecorated_name + '.dll'
        elif platform == 'linux': decorated_name = 'lib' + undecorated_name + '.so'
        elif platform == 'osx': decorated_name = 'lib' + undecorated_name + '.dylib'
        elif platform == 'asmjs': fail('Building dynamic libraries for asmjs is not yet supported.')
        else: fail('Unexpected platform %s. Expected values are "windows", "linux", "osx", "asmjs".' % platform)
    else: fail('Unexpected output_type %s. Expected values are "executable", "dynamic_library".' % output_type)
    return decorated_name

def _tab_cc_shared_library_internal_rule_impl(ctx):
    cc_toolchain = find_cpp_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )

    # print(feature_configuration)

    pic_enabled = cc_common.is_enabled(feature_configuration = feature_configuration, feature_name = 'pic')

    output_type = "dynamic_library" if ctx.attr._linkshared else "executable"
    base_binary_name = ctx.attr.binary_name if ctx.attr.binary_name else ctx.label.name
    output_name = decorate_name(base_binary_name, output_type, ctx.attr.platform)

    all_deps = ctx.attr.deps + ctx.attr.public_deps

    compilation_contexts = [] # Used directly in cc_common.compile call below
    linking_contexts = []
    for dep in all_deps:
        if CcInfo in dep:
            compilation_contexts.append(dep[CcInfo].compilation_context)
            # describe(dep[CcInfo].compilation_context, 'dep[CcInfo].compilation_context ' + dep.label.name)
            linking_contexts.append(dep[CcInfo].linking_context)
            # describe(dep[CcInfo].linking_context, 'dep[CcInfo].linking_context ' + dep.label.name)
    linker_inputs = deduplicate_linker_inputs(linking_contexts)

    # Converting cc_binary API to cc_common API.
    filtered_srcs = []
    private_hdrs = []
    for file in ctx.files.srcs:
        # print('file.extension = %s' % file.extension)
        if file.extension in ["cc", "cpp", "cxx", "c++", "C", "cu", "cl", "c", "s", "asm"]:
            filtered_srcs.append(file)
        else:
            private_hdrs.append(file)

    # describe(ctx.attr.hdrs, 'ctx.attr.hdrs for %s' % ctx.label)
    # describe(ctx.files.hdrs, 'ctx.files.hdrs for %s' % ctx.label)

    hdrs = []
    for file in ctx.files.hdrs:
        # We don't let headers with no extension reach to cc_common.compile and confuse it
        # But at the same time they are discoverable for collect_deps.
        if not file.extension == '':
            hdrs.append(file)
    # describe(hdrs, 'hdrs for %s' % ctx.label)

    # To mimic cc_library behavior we need to translate "includes" attribute to "system_includes".
    system_includes_list = []
    for include_folder in ctx.attr.includes:
        system_include = paths.normalize(paths.join(ctx.label.workspace_root, ctx.label.package, include_folder))
        system_includes_list.append(system_include)
        system_include_from_execroot = paths.join(ctx.bin_dir.path, system_include)
        system_includes_list.append(system_include_from_execroot)
    # describe(system_includes_list, 'system_includes_list')

    # Create compilation context for the newly created binary.
    # Combine it with the compilation contexts of public dependencies to propagate upstream.
    new_compilation_context = cc_common.create_compilation_context(
        headers = depset(ctx.files.hdrs),
        system_includes = depset(system_includes_list),
        defines = depset(ctx.attr.defines),
        # No need to add local_defines here as this compilation_context is not used for compilation, but used only to convey info to dependendents.
    )

    # print('filtered_srcs = %s' % filtered_srcs)
    # print('hdrs = %s' % hdrs)

    # describe(compilation_context, 'compilation_context_from_create')
    (compiled_compilation_context, compilation_outputs) = cc_common.compile(
        # This name seems to control the name of the folder inside _objs where object files are stored.
        name = output_name,
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        srcs = filtered_srcs,
        private_hdrs = private_hdrs,
        public_hdrs = hdrs,
        includes = ctx.attr.includes,
        system_includes = system_includes_list,
        defines = ctx.attr.defines,
        local_defines = ctx.attr.local_defines,
        user_compile_flags = ctx.attr.copts,
        # additional_inputs = ? Do we need it?
        include_prefix = ctx.attr.include_prefix,
        strip_include_prefix = ctx.attr.strip_include_prefix,
        compilation_contexts = compilation_contexts,
        # Without that in "opt" mode on Linux we get both PIC and noPIC object files
        disallow_nopic_outputs = True if ctx.attr.platform != 'windows' else False,
    )

    # describe(compilation_outputs, ctx.label.name)

    # Working on the linking part now.
    user_link_flags = []
    for user_link_flag in ctx.attr.linkopts:
        user_link_flags.append(ctx.expand_location(user_link_flag, targets = ctx.attr.additional_linker_inputs))

    malloc = ctx.attr._custom_malloc or ctx.attr.malloc
    linking_contexts.append(malloc[CcInfo].linking_context)

    # This whole mechanism is WIP. Another part is in "@tab_toolchains//bazel/toolchains:runtime_libs.bzl"
    # Even in the partially implemented state this is necessary for OSX build to find its runtime.
    runtime_libs = []
    static_link_cpp_runtimes_enabled = cc_common.is_enabled(feature_configuration = feature_configuration, feature_name = 'static_link_cpp_runtimes')
    # print('static_link_cpp_runtimes_enabled = %s' % static_link_cpp_runtimes_enabled)
    # See comments here: https://cs.opensource.google/bazel/bazel/+/master:src/main/java/com/google/devtools/build/lib/skylarkbuildapi/cpp/CcToolchainProviderApi.java;drc=b017468d07da1e45282b9d153a4308fdace11eeb;l=68
    if static_link_cpp_runtimes_enabled:
        static_linking_mode_enabled = cc_common.is_enabled(feature_configuration = feature_configuration, feature_name = 'static_linking_mode')
        dynamic_linking_mode_enabled = cc_common.is_enabled(feature_configuration = feature_configuration, feature_name = 'dynamic_linking_mode')
        # print('static_linking_mode_enabled = %s, dynamic_linking_mode_enabled = %s' % (static_linking_mode_enabled, dynamic_linking_mode_enabled))

        if static_linking_mode_enabled:
            if ctx.attr.platform == 'windows':
                runtime_libs = ctx.attr.static_runtime_lib
            else:
                runtime_libs = cc_toolchain.static_runtime_lib(feature_configuration = feature_configuration).to_list()
        elif dynamic_linking_mode_enabled:
            if ctx.attr.platform == 'windows':
                runtime_libs = ctx.attr.dynamic_runtime_lib
            else:
                runtime_libs = cc_toolchain.dynamic_runtime_lib(feature_configuration = feature_configuration).to_list()
        # describe(runtime_libs, 'runtime_libs')

    link_output_file, output_file_import_lib, output_file_exp, output_file_pdb = link(
        output_name = output_name,
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        compilation_outputs = compilation_outputs,
        linker_inputs = linker_inputs,
        user_link_flags = user_link_flags,
        link_deps_statically = ctx.attr.linkstatic,
        stamp = ctx.attr.stamp,
        additional_inputs = ctx.files.additional_linker_inputs,
        output_type = output_type,
        # Non-standard parameters
        ctx = ctx,
        platform = ctx.attr.platform,
        runtime_libs = runtime_libs,
    )

    ccinfo_list = [] # Collecting CcInfos to pass to dependencies

    # Non-public deps are not propagated down the dependency chain.
    # Private dynamic libs are not taken and therefore are not copied to the output folder
    # by the standard copy_dynamic_libraries_to_binary feature.
    # To compensate for that we have custom copy_dynamic_libraries_to_binary.bzl

    # Approach #1: collect CcInfo from all public dependencies.
    # for public_dep in ctx.attr.public_deps:
    #     if CcInfo in public_dep:
    #         ccinfo_list.append(public_dep[CcInfo])

    # Approach #2: 
    # Collect compilation_contexts and linking_contexts from public deps.
    public_compilation_contexts = []
    public_linking_contexts = []
    for dep in ctx.attr.public_deps:
        if CcInfo in dep:
            public_compilation_contexts.append(dep[CcInfo].compilation_context)
            # describe(dep[CcInfo].compilation_context, 'dep[CcInfo].compilation_context ' + dep.label.name)
            public_linking_contexts.append(dep[CcInfo].linking_context)
            # describe(dep[CcInfo].linking_context, 'dep[CcInfo].linking_context ' + dep.label.name)

    # Combine public compilation contexts to ccinfo_list.
    for public_compilation_context in public_compilation_contexts:
        dep_ccinfo = CcInfo(compilation_context = public_compilation_context, linking_context = None)
        ccinfo_list.append(dep_ccinfo)

    # Collect linker_inputs from public deps
    public_linker_inputs = deduplicate_linker_inputs(public_linking_contexts)
    non_empty_public_linker_inputs = filter_empty_linker_inputs(public_linker_inputs)

    # Filter out static libraries - currently commented out.
    # The idea is - static libraries are now linked into the currently built shared library 
    # and static library symbols are now exposed by the shared library.
    # filtered_linker_inputs = filter_static_libs_from_linker_inputs(non_empty_public_linker_inputs, pic_enabled, ctx.attr.linkstatic)

    # Current thinking is that we should not filter out static libraries.
    filtered_linker_inputs = non_empty_public_linker_inputs

    # Combine filtered linker inputs into ccinfo_list.
    deps_linking_context = cc_common.create_linking_context(linker_inputs = depset(filtered_linker_inputs))
    dep_ccinfo = CcInfo(compilation_context = None, linking_context = deps_linking_context)
    ccinfo_list.append(dep_ccinfo)

    # We intentionally do this even for output_type == "executable".
    # describe(link_output_file, 'link_output_file (%s)' % ctx.label)
    new_library_to_link = cc_common.create_library_to_link(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        dynamic_library = link_output_file,
        # dynamic_library_symlink_path = link_output_file.path,
        interface_library = output_file_import_lib,
        # interface_library_symlink_path = output_file_import_lib.path if output_file_import_lib else '',
    )
    # describe(library_to_link, 'library_to_link (%s' % ctx.label)
    new_linker_input = cc_common.create_linker_input(owner = ctx.label, libraries = depset([new_library_to_link]))
    new_linking_context = cc_common.create_linking_context(linker_inputs = depset([new_linker_input]))
    # describe(new_linking_context, "new_linking_context (%s)" % ctx.label)

    # Add newly generated cc_info to the list of public deps.
    # Here we may consider using compiled_compilation_context instead of new_compilation_context.
    new_ccinfo = CcInfo(compilation_context = new_compilation_context, linking_context = new_linking_context)
    # describe(new_linking_context, 'new_linking_context (%s)' % ctx.label)

    # Create final merged CcInfo to return
    merged_ccinfo = cc_common.merge_cc_infos(direct_cc_infos = [new_ccinfo], cc_infos = ccinfo_list)
    # describe(merged_ccinfo.linking_context, 'merged_ccinfo.linking_context (%s)' % ctx.label)
    
    objects = []
    if pic_enabled:
        objects.extend(compilation_outputs.pic_objects)
    else:
        objects.extend(compilation_outputs.objects)

    # I tried to set it to library_to_link.dynamic_library to better match what built-in rules are doing, but
    # it created a problem for dsymutil on Mac - it seems it cannot handle a path with the "@" symbol in it.
    output_dynamic_library = link_output_file

    # We need to match the return structure with tab_cc_funnel_internal
    # Also we MAY need to collect extra libraries from srcs similar to how tab_cc_funnel_internal does it.
    output_group_info = OutputGroupInfo(
        compilation_outputs = depset(objects),
        dynamic_library = depset([output_dynamic_library]),
        interface_library = depset([output_file_import_lib]) if output_file_import_lib else depset([]),
        exp_file = depset([output_file_exp]) if output_file_exp else depset([]),
        pdb_file = depset([output_file_pdb]) if output_file_pdb else depset([]),
    )
    # describe(link_output_file, output_name)
    return [
        DefaultInfo(
            files = depset([output_dynamic_library]),
            # Setting "executable" causes creation of runfiles.
            executable = link_output_file if output_type == "executable" else None,
        ),
        merged_ccinfo,
        output_group_info,
    ]

tab_cc_shared_library_internal_rule = rule(
    implementation = _tab_cc_shared_library_internal_rule_impl,
    attrs = {
        "binary_name": attr.string(),
        "srcs": attr.label_list(allow_files = True),
        "hdrs": attr.label_list(allow_files = True),
        "includes": attr.string_list(allow_empty = True),
        "defines": attr.string_list(allow_empty = True),
        "local_defines": attr.string_list(allow_empty = True),
        "deps": attr.label_list(
            allow_empty = True,
            providers = [CcInfo],
        ),
        "public_deps": attr.label_list(
            allow_empty = True,
            providers = [CcInfo],
        ),
        "copts": attr.string_list(allow_empty = True),
        "linkopts": attr.string_list(allow_empty = True),
        "linkstatic": attr.bool(default = True),
        "_linkshared": attr.bool(default = True),
        "platform": attr.string(mandatory = True),
        "data": attr.label_list(
            default = [],
            allow_files = True,
        ),
        "include_prefix": attr.string(),
        "strip_include_prefix": attr.string(),
        "static_runtime_lib": attr.label_list(),
        "dynamic_runtime_lib": attr.label_list(),
        "additional_linker_inputs": attr.label_list(
            allow_empty = True,
            allow_files = [".lds"],
        ),
        "stamp": attr.int(default = -1),
        "malloc": attr.label(
            default = "@bazel_tools//tools/cpp:malloc",
            providers = [CcInfo],
        ),
        # Exposes --custom_malloc flag, if you really need behavior to match
        # native.cc_binary and have that override the malloc attr.
        "_custom_malloc": attr.label(
            default = configuration_field(
                fragment = "cpp",
                name = "custom_malloc",
            ),
            providers = [CcInfo],
        ),
        "_cc_toolchain": attr.label(default = "@bazel_tools//tools/cpp:current_cc_toolchain"),
    },
    fragments = ["cpp"],
    toolchains = ["@rules_cc//cc:toolchain_type"],
)

# buildifier: disable=function-docstring
def tab_cc_shared_library_internal(**attrs):
    # print('attrs[name] = %s, attrs[linkopts] = %s' % (attrs.get("name"), attrs.get("linkopts")))

    # Enforce that tab_cc_shared_library only uses linkstatic = True.
    if attrs.get("linkstatic") == False:
        fail('tab_cc_shared_library only intended to be used with "linkstatic = True". %s' % location(attrs))
    attrs["linkstatic"] = True

    feature_flag = "!use_macro"
    if feature_flag == "use_macro":
        # For native cc_library public and regular deps are the same.
        public_deps = attrs.pop("public_deps", None)
        add_to_list_attribute(attrs, "deps", public_deps)

        tab_cc_shared_library_macro(**attrs)
        return


    filtered_attrs = filter_attributes(**attrs)
    if len(filtered_attrs) == 0:
        return

    filtered_attrs['static_runtime_lib'] = runtime_static_library_files
    filtered_attrs['dynamic_runtime_lib'] = runtime_shared_library_files

    # print('\n%s is a shared library' % name)
    tab_cc_shared_library_internal_rule(**filtered_attrs)

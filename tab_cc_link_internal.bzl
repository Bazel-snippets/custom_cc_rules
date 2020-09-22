# buildifier: disable=module-docstring
load("@bazel_skylib//lib:paths.bzl", "paths")
load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@tab_toolchains//cc:tab_cc_helpers_internal.bzl", "resolve_library")
load("@tab_toolchains//bazel/rules:debug.bzl", "describe")

def strip_prefix(string, prefix):
    if not string.startswith(prefix):
        return string
    return string[len(prefix):]

def strip_suffix(string, suffix):
    index = string.rfind(suffix)
    if index == -1:
        return string
    return string[:index]

def strip(string, prefix, suffix):
    # no_prefix = strip_prefix(string, prefix)
    # print('no_prefix = %s' % no_prefix)
    # stripped = strip_suffix(no_prefix, suffix)
    # print('stripped = %s' % stripped)
    return strip_suffix(strip_prefix(string, prefix), suffix)

# buildifier: disable=function-docstring
def undecorate_name(decorated_name, output_type, platform):
    if output_type == "executable":
        if   platform == 'windows': undecorated_name = strip_suffix(decorated_name, '.exe')
        elif platform == 'linux': undecorated_name = decorated_name
        elif platform == 'osx': undecorated_name = decorated_name
        elif platform == 'asmjs': fail('Building executables for asmjs is not yet supported.')
        else: fail('Unexpected platform %s. Expected values are "windows", "linux", "osx", "asmjs".' % platform)
    elif output_type == "dynamic_library":
        if   platform == 'windows': undecorated_name = strip_suffix(decorated_name, '.dll')
        elif platform == 'linux': undecorated_name = strip(decorated_name, 'lib', '.so')
        elif platform == 'osx': undecorated_name = strip(decorated_name, 'lib', '.dylib')
        elif platform == 'asmjs': fail('Building dynamic libraries for asmjs is not yet supported.')
        else: fail('Unexpected platform %s. Expected values are "windows", "linux", "osx", "asmjs".' % platform)
    else: fail('Unexpected output_type %s. Expected values are "executable", "dynamic_library".' % output_type)
    return undecorated_name

# buildifier: disable=function-docstring
def link(
    output_name,
    actions,
    feature_configuration,
    cc_toolchain,
    compilation_outputs,
    linker_inputs,
    user_link_flags,
    link_deps_statically,
    stamp,
    additional_inputs, # Not currently used
    output_type,
    # Non-standard parameters
    ctx,
    platform,
    runtime_libs,
):

    if   output_type == "executable": action_name = ACTION_NAMES.cpp_link_executable
    elif output_type == "dynamic_library": action_name = ACTION_NAMES.cpp_link_dynamic_library
    else: fail('Unexpected output_type %s. Expected values are "executable", "dynamic_library".' % output_type)

    output_file = ctx.actions.declare_file(output_name)
    # describe(output_file, 'output_file')
    outputs = [output_file]

    # supports_pic_enabled = cc_common.is_enabled(feature_configuration = feature_configuration, feature_name = 'supports_pic')
    pic_enabled = cc_common.is_enabled(feature_configuration = feature_configuration, feature_name = 'pic')
    # print('supports_pic_enabled = %s, pic_enabled = %s' % (supports_pic_enabled, pic_enabled))

    files_to_link = []
    if pic_enabled:
        for obj in compilation_outputs.pic_objects:
            files_to_link.append(obj)
        if len(compilation_outputs.objects) > 0:
            fail('ASSERT: PIC is enabled, but we still get non-PIC object files for linking: %s' % compilation_outputs.objects)
    else:
        for obj in compilation_outputs.objects:
            files_to_link.append(obj)
        if len(compilation_outputs.pic_objects) > 0:
            fail('ASSERT: PIC is NOT enabled, but we still get PIC object files for linking: %s' % compilation_outputs.pic_objects)

    library_search_directories = []
    runtime_library_search_directories = []
    shared_library_names = {}
    shared_library_files_for_sandbox = []
    static_alwayslink_lib_files = []
    for linker_input in linker_inputs:
        for library in linker_input.libraries:
            # describe(library, output_name)

            # I don't know what to do if dependency comes with the object files.
            # if pic_enabled:
            #     for obj in library.pic_objects:
            #         files_to_link.append(obj)
            #     if len(library.objects) > 0:
            #         fail('ASSERT: PIC is enabled, but we still get non-PIC object files for linking: %s' % library.objects)
            # else:
            #     for obj in library.objects:
            #         files_to_link.append(obj)
            #     if len(library.pic_objects) > 0:
            #         fail('ASSERT: PIC is NOT enabled, but we still get PIC object files for linking: %s' % library.pic_objects)

            file_to_link, file_to_link_type = resolve_library(library, pic_enabled, link_deps_statically)

            if file_to_link_type == "Dynamic":
                shared_library_files_for_sandbox.append(file_to_link)
                shared_library_names[file_to_link.basename] = True
                library_search_directories.append(file_to_link.dirname)
                runtime_library_search_directories.append(file_to_link.dirname)
            elif file_to_link_type == "Static" and library.alwayslink:
                static_alwayslink_lib_files.append(file_to_link)
            else:
                files_to_link.append(file_to_link)

    # describe(library_search_directories, 'library_search_directories')
    # describe(runtime_library_search_directories, 'runtime_library_search_directories')

    static_link_cpp_runtimes_enabled = cc_common.is_enabled(feature_configuration = feature_configuration, feature_name = 'static_link_cpp_runtimes')
    if static_link_cpp_runtimes_enabled:
        static_linking_mode_enabled = cc_common.is_enabled(feature_configuration = feature_configuration, feature_name = 'static_linking_mode')
        dynamic_linking_mode_enabled = cc_common.is_enabled(feature_configuration = feature_configuration, feature_name = 'dynamic_linking_mode')
        # print('static_linking_mode_enabled = %s, dynamic_linking_mode_enabled = %s' % (static_linking_mode_enabled, dynamic_linking_mode_enabled))
        if static_linking_mode_enabled:
            files_to_link.extend(runtime_libs)
        if dynamic_linking_mode_enabled:
            for runtime_lib in runtime_libs:
                shared_library_names[runtime_lib.basename] = True

    file_to_link_path_list = []
    for file_to_link in files_to_link:
        file_to_link_path_list.append(file_to_link.path)
    
    # The notion "-l<undecorated name>" is the only one which works on OSX.
    for shared_library_name in shared_library_names.keys():
        # print('shared_library_name = %s' % shared_library_name)
        if platform == 'linux':
            file_to_link_path_list.append('-l:' + shared_library_name)
        else:
            file_to_link_path_list.append('-l' + undecorate_name(shared_library_name, output_type, platform))

    for static_alwayslink_lib_file in static_alwayslink_lib_files:
        if platform == 'windows':
            file_to_link_path_list.append('/WHOLEARCHIVE:' + static_alwayslink_lib_file.path)
        elif platform == 'osx':
            file_to_link_path_list.append('-Wl,-force_load,' + static_alwayslink_lib_file.path)
        else:
            file_to_link_path_list.append('-Wl,-whole-archive')
            file_to_link_path_list.append(static_alwayslink_lib_file.path)
            file_to_link_path_list.append('-Wl,-no-whole-archive')

    # Corresponding setting in toolchain is in bazel\toolchains\tab_msvc\BUILD.tab_msvc_toolchain.tpl - "supports_param_files".
    # TODO: try to set use_response_file here from toolchain setting supports_param_files.
    use_response_file = False

    param_file = None
    if use_response_file:
        param_file_name = (output_name + ".param")
        param_file = ctx.actions.declare_file(param_file_name)
        ctx.actions.write(param_file, "\n".join(file_to_link_path_list))

    link_flags = []
    if not use_response_file:
        link_flags += file_to_link_path_list

    if platform == 'osx' and output_type == "dynamic_library":
        link_flags.append("-Wl,-install_name,@rpath/{}".format(output_name))

    if platform == 'linux' and output_type == "dynamic_library":
        link_flags.append("-Wl,-soname={}".format(output_name))

    # describe(user_link_flags, 'user_link_flags')
    for user_link_flag in user_link_flags:
        link_flags.extend(user_link_flag.split(' '))

    # We may need to add link flags from dependencies, but for now I (Konstantin) decided to go without it. Also we don't have combined linking_context readily available.
    # link_flags += linking_context.user_link_flags

    output_file_import_lib = None
    output_file_exp = None
    output_file_def = None
    output_file_pdb = None
    if ctx.attr.platform == "windows":
        if output_type == "dynamic_library":
            output_file_import_lib = ctx.actions.declare_file(paths.replace_extension(output_name, ".lib"))
            outputs.append(output_file_import_lib)
            output_file_exp = ctx.actions.declare_file(paths.replace_extension(output_name, ".exp"))
            outputs.append(output_file_exp)
            # DEF file is needed so that import lib is always created.
            output_file_def = ctx.actions.declare_file(output_name + '.gen.empty.def') # Extension copied from what cc_binary is doing.
            ctx.actions.write(output_file_def, "") # Create empty file.

        generate_pdb_file_enabled = cc_common.is_enabled(feature_configuration = feature_configuration, feature_name = 'generate_pdb_file')
        if generate_pdb_file_enabled:
            output_file_pdb = ctx.actions.declare_file(paths.replace_extension(output_name, ".pdb"))
            outputs.append(output_file_pdb)
    
    # library_search_directories_enabled = cc_common.is_enabled(feature_configuration = feature_configuration, feature_name = 'library_search_directories')
    # print('library_search_directories_enabled = %s' % library_search_directories_enabled)
    
    link_variables = cc_common.create_link_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        library_search_directories = depset(library_search_directories), 
        runtime_library_search_directories = depset(runtime_library_search_directories),
        output_file = output_file.path,
        is_using_linker = True,
        is_linking_dynamic_library = True if output_type == "dynamic_library" else False, # Don't know what it actually changes.
        param_file = param_file.path if use_response_file else None,
        user_link_flags = link_flags,
        must_keep_debug = True,
        def_file = output_file_def.path if output_file_def else None, # This is where "def_file_path" build variable is set.
    )
    # print("link_variables = %s" % link_variables)
    # print(repr(link_variables))
    # describe(cc_toolchain)
    # runtime_library_search_directories_enabled = cc_common.is_enabled(feature_configuration = feature_configuration, feature_name = 'runtime_library_search_directories')
    # print('runtime_library_search_directories_enabled = %s' % runtime_library_search_directories_enabled)

    command_line = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = action_name,
        variables = link_variables,
    )
    # describe(command_line, "command_line")

    # This is the test which features are enabled.
    # input_param_flags_enabled = cc_common.is_enabled(feature_configuration = feature_configuration, feature_name = 'input_param_flags')
    # def_file_enabled = cc_common.is_enabled(feature_configuration = feature_configuration, feature_name = 'def_file')
    # print('Linking %s' % output_name)
    # print('input_param_flags_enabled = %s, def_file_enabled = %s' % (input_param_flags_enabled, def_file_enabled))

    # Here comes IMPLIB mystery:
    # Normally /IMPLIB linker option supposed to come from the toolchain when the feature "input_param_flags" is enabled.
    # Variable "input_param_flags_enabled" above reports that the feature "input_param_flags" is indeed enabled.
    # Still the linker option "/IMPLIB" DOES NOT come from the toolchain, which means "interface_library_output_path" build variable is not set.
    # How to set it? I don't know. cc_binary apparently does it and the option does come from the toolchain.
    # Luckily we are better of without that option than with it. 
    #   Without it import library is created with the default extension .lib
    #   With it "interface_library_output_path" forces the extension to be weird .dll.if.lib which we don't want.

    # This is the boilerplate for the experiments with the command line.
    patched_command_line = []
    patched_command_line.extend(command_line)
    # patched_command_line.append('/VERBOSE') # This works on Linux
    # patched_command_line.append('--verbose') # This works on Linux
    # patched_command_line.append('-t') # This works on MacOS
    # patched_command_line.append('-whyload') # This works on MacOS
    # patched_command_line.append('/IMPLIB:%s' % output_file_import_lib.path)
    # describe(patched_command_line, "command_line")

    #args = ctx.actions.args()
    #args.add_all(command_line)

    env = cc_common.get_environment_variables(
        feature_configuration = feature_configuration,
        action_name = action_name,
        variables = link_variables,
    )
    # print(env)

    inputs = files_to_link
    inputs.extend(shared_library_files_for_sandbox)
    inputs.extend(static_alwayslink_lib_files)
    if param_file:
        inputs.append(param_file)
    if output_file_def:
        inputs.append(output_file_def)
    # print(inputs)

    linker_path = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = action_name,
    )

    ctx.actions.run(
        executable = linker_path,
        arguments = patched_command_line,
        use_default_shell_env = False, # This is to prevent leaking of the real PATH to the action environment
        env = env,
        inputs = depset(
            direct = inputs,
            transitive = [cc_toolchain.all_files], # TODO: this can be done more precise
        ),
        outputs = outputs,
        mnemonic = "CppLink",
    )

    return output_file, output_file_import_lib, output_file_exp, output_file_pdb

# Remaining differences from cc_binary:

# cc_toolchain(
#     name = "clang_linux",
#     dynamic_runtime_lib = "@gnu_linux//:cpp_dynamic_runtime_libraries",

# environment variables set through --action_env=
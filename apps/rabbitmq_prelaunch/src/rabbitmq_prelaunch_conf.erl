-module(rabbitmq_prelaunch_conf).

-include_lib("kernel/include/file.hrl").
-include_lib("stdlib/include/zip.hrl").

-include_lib("rabbit_common/include/rabbit.hrl").

-export([setup/0,
         setup/1,
         generate_config_from_cuttlefish_files/3]).

setup() ->
    case rabbitmq_prelaunch_helpers:get_env(context) of
        {ok, Context} ->
            setup(Context);
        undefined ->
            throw({error, initial_setup_not_executed})
    end.

setup(Context) ->
    rabbit_log_prelaunch:debug(""),
    rabbit_log_prelaunch:debug("== Configuration =="),

    %% TODO: Check if directories/files are inside Mnesia dir.

    %% TODO: Support glob patterns & directories in RABBITMQ_CONFIG_FILE.
    %% TODO: Always try parsing of both erlang and cuttlefish formats.

    update_enabled_plugins_file(Context),

    AdvancedConfigFile = find_actual_advanced_config_file(Context),
    State = case find_actual_main_config_file(Context) of
                {MainConfigFile, erlang} ->
                    load_erlang_term_based_config_file(MainConfigFile),
                    #{config_type => erlang,
                      config_files => [MainConfigFile],
                      config_advanced_file => undefined};
                {MainConfigFile, cuttlefish} ->
                    ConfigFiles = [MainConfigFile],
                    load_cuttlefish_config_file(Context,
                                                ConfigFiles,
                                                AdvancedConfigFile),
                    #{config_type => cuttlefish,
                      config_files => ConfigFiles,
                      config_advanced_file => AdvancedConfigFile};
                undefined when AdvancedConfigFile =/= undefined ->
                    rabbit_log_prelaunch:warning(
                      "Using RABBITMQ_ADVANCED_CONFIG_FILE: ~s",
                      [AdvancedConfigFile]),
                    load_erlang_term_based_config_file(AdvancedConfigFile),
                    #{config_type => erlang,
                      config_files => [AdvancedConfigFile],
                      config_advanced_file => AdvancedConfigFile};
                undefined ->
                    #{config_type => undefined,
                      config_files => [],
                      config_advanced_file => undefined}
            end,
    rabbit_log_prelaunch:debug(
      "Saving config state to application env: ~p", [State]),
    rabbitmq_prelaunch_helpers:set_env(config_state, State).

update_enabled_plugins_file(Context) ->
    %% We only do this on startup, not when the configuration is
    %% reloaded.
    case rabbitmq_prelaunch_helpers:get_env(config_state) of
        {ok, _}   -> ok;
        undefined -> update_enabled_plugins_file1(Context)
    end.

update_enabled_plugins_file1(#{enabled_plugins := undefined}) ->
    ok;
update_enabled_plugins_file1(#{enabled_plugins := all,
                              plugins_path := Path} = Context) ->
    List = [P#plugin.name || P <- rabbit_plugins:list(Path)],
    do_update_enabled_plugins_file(Context, List);
update_enabled_plugins_file1(#{enabled_plugins := List} = Context) ->
    do_update_enabled_plugins_file(Context, List).

do_update_enabled_plugins_file(#{enabled_plugins_file := File}, List) ->
    SortedList = lists:usort(List),
    case SortedList of
        [] ->
            rabbit_log_prelaunch:debug("Marking all plugins as disabled");
        _ ->
            rabbit_log_prelaunch:debug(
              "Marking the following plugins as enabled:"),
            [rabbit_log_prelaunch:debug("  - ~s", [P]) || P <- SortedList]
    end,
    Content = io_lib:format("~p.~n", [SortedList]),
    case file:write_file(File, Content) of
        ok ->
            ok;
        {error, Reason} ->
            rabbit_log_prelaunch:error(
              "Failed to update enabled plugins file \"~ts\" "
              "from $RABBITMQ_ENABLED_PLUGINS: ~ts",
              [File, file:format_error(Reason)]),
            throw({error, failed_to_update_enabled_plugins_file})
    end.

find_actual_main_config_file(#{main_config_file := File}) ->
    case filelib:is_regular(File) of
        true ->
            Format = case filename:extension(File) of
                ".conf"   -> cuttlefish;
                ".config" -> erlang;
                _         -> determine_config_format(File)
            end,
            {File, Format};
        false ->
            OldFormatFile = File ++ ".config",
            NewFormatFile = File ++ ".conf",
            case filelib:is_regular(OldFormatFile) of
                true ->
                    case filelib:is_regular(NewFormatFile) of
                        true ->
                            rabbit_log_prelaunch:warning(
                              "Both old (.config) and new (.conf) format config "
                              "files exist."),
                            rabbit_log_prelaunch:warning(
                              "Using the old format config file: ~s",
                              [OldFormatFile]),
                            rabbit_log_prelaunch:warning(
                              "Please update your config files to the new format "
                              "and remove the old file."),
                            ok;
                        false ->
                            ok
                    end,
                    {OldFormatFile, erlang};
                false ->
                    case filelib:is_regular(NewFormatFile) of
                        true  -> {NewFormatFile, cuttlefish};
                        false -> undefined
                    end
            end
    end.

find_actual_advanced_config_file(#{advanced_config_file := File}) ->
    case filelib:is_regular(File) of
        true  -> File;
        false -> undefined
    end.

determine_config_format(File) ->
    case filelib:filesize(File) of
        0 ->
            cuttlefish;
        _ ->
            case file:consult(File) of
                {ok, _} -> erlang;
                _       -> cuttlefish
            end
    end.

load_erlang_term_based_config_file(ConfigFile) ->
    rabbit_log_prelaunch:debug(
      "Loading configuration file \"~ts\" (Erlang terms based)", [ConfigFile]),
    case file:consult(ConfigFile) of
        {ok, [Config]} when is_list(Config) ->
            apply_erlang_term_based_config(Config);
        {ok, OtherTerms} ->
            rabbit_log_prelaunch:error(
              "Failed to load configuration file \"~ts\", "
              "incorrect format: ~p",
              [ConfigFile, OtherTerms]),
            throw({error, failed_to_parse_configuration_file});
        {error, Reason} ->
            rabbit_log_prelaunch:error(
              "Failed to load configuration file \"~ts\": ~ts",
              [ConfigFile, file:format_error(Reason)]),
            throw({error, failed_to_read_configuration_file})
    end.

load_cuttlefish_config_file(Context,
                            ConfigFiles,
                            AdvancedConfigFile) ->
    Config = generate_config_from_cuttlefish_files(
               Context, ConfigFiles, AdvancedConfigFile),
    apply_erlang_term_based_config(Config),
    ok.

generate_config_from_cuttlefish_files(Context,
                                      ConfigFiles,
                                      AdvancedConfigFile) ->
    %% Load schemas.
    SchemaFiles = find_cuttlefish_schemas(Context),
    case SchemaFiles of
        [] ->
            rabbit_log_prelaunch:error(
              "No configuration schema found~n", []),
            throw({error, no_configuration_schema_found});
        _ ->
            rabbit_log_prelaunch:debug(
              "Configuration schemas found:~n", []),
            [rabbit_log_prelaunch:debug("  - ~ts", [SchemaFile])
             || SchemaFile <- SchemaFiles],
            ok
    end,
    Schema = cuttlefish_schema:files(SchemaFiles),

    %% Load configuration.
    rabbit_log_prelaunch:debug(
      "Loading configuration files (Cuttlefish based):"),
    [rabbit_log_prelaunch:debug(
       "  - ~ts", [ConfigFile]) || ConfigFile <- ConfigFiles],
    Config0 = cuttlefish_conf:files(ConfigFiles),

    %% Finalize configuration, based on the schema.
    Config = case cuttlefish_generator:map(Schema, Config0) of
                 {error, Phase, {errorlist, Errors}} ->
                     %% TODO
                     rabbit_log_prelaunch:error(
                       "Error generating configuration in phase ~ts:",
                       [Phase, Errors]),
                     [rabbit_log_prelaunch:error(
                        "  - ~ts",
                        [cuttlefish_error:xlate(Error)])
                      || Error <- Errors],
                     throw({error, failed_to_generate_configuration_file});
                 ValidConfig ->
                     proplists:delete(vm_args, ValidConfig)
             end,

    %% Apply advanced configuration overrides, if any.
    override_with_advanced_config(Config, AdvancedConfigFile).

find_cuttlefish_schemas(Context) ->
    Apps = list_apps(Context),
    rabbit_log_prelaunch:debug(
      "Looking up configuration schemas in the following applications:"),
    find_cuttlefish_schemas(Apps, []).

find_cuttlefish_schemas([App | Rest], AllSchemas) ->
    Schemas = list_schemas_in_app(App),
    find_cuttlefish_schemas(Rest, AllSchemas ++ Schemas);
find_cuttlefish_schemas([], AllSchemas) ->
    lists:sort(fun(A,B) -> A < B end, AllSchemas).

list_apps(#{os_type := {win32, _}, plugins_path := PluginsPath}) ->
    PluginsDirs = string:lexemes(PluginsPath, ";"),
    list_apps1(PluginsDirs, []);
list_apps(#{plugins_path := PluginsPath}) ->
    PluginsDirs = string:lexemes(PluginsPath, ":"),
    list_apps1(PluginsDirs, []).


list_apps1([Dir | Rest], Apps) ->
    case file:list_dir(Dir) of
        {ok, Filenames} ->
            NewApps = [list_to_atom(
                         hd(
                           string:split(filename:basename(F, ".ex"), "-")))
                       || F <- Filenames],
            Apps1 = lists:umerge(Apps, lists:sort(NewApps)),
            list_apps1(Rest, Apps1);
        {error, Reason} ->
            rabbit_log_prelaunch:debug(
              "Failed to list directory \"~ts\" content: ~ts",
              [Dir, file:format_error(Reason)]),
            list_apps1(Rest, Apps)
    end;
list_apps1([], AppInfos) ->
    AppInfos.

list_schemas_in_app(App) ->
    {Loaded, Unload} = case application:load(App) of
                           ok                           -> {true, true};
                           {error, {already_loaded, _}} -> {true, false};
                           {error, _}                   -> {false, false}
                       end,
    List = case Loaded of
               true ->
                   case code:priv_dir(App) of
                       {error, bad_name} ->
                           rabbit_log_prelaunch:debug(
                             "  [ ] ~s (no readable priv dir)", [App]),
                           [];
                       PrivDir ->
                           SchemaDir = filename:join([PrivDir, "schema"]),
                           do_list_schemas_in_app(App, SchemaDir)
                   end;
               false ->
                   rabbit_log_prelaunch:debug(
                     "  [ ] ~s (failed to load application)", [App]),
                   []
           end,
    case Unload of
        true  -> application:unload(App);
        false -> ok
    end,
    List.

do_list_schemas_in_app(App, SchemaDir) ->
    case erl_prim_loader:list_dir(SchemaDir) of
        {ok, Files} ->
            rabbit_log_prelaunch:debug("  [x] ~s", [App]),
            [filename:join(SchemaDir, File)
             || [C | _] = File <- Files,
                C =/= $.];
        error ->
            rabbit_log_prelaunch:debug(
              "  [ ] ~s (no readable schema dir)", [App]),
            []
    end.

override_with_advanced_config(Config, undefined) ->
    Config;
override_with_advanced_config(Config, AdvancedConfigFile) ->
    rabbit_log_prelaunch:debug(
      "Override with advanced configuration file \"~ts\"",
      [AdvancedConfigFile]),
    case file:consult(AdvancedConfigFile) of
        {ok, [AdvancedConfig]} ->
            cuttlefish_advanced:overlay(Config, AdvancedConfig);
        {ok, OtherTerms} ->
            rabbit_log_prelaunch:error(
              "Failed to load advanced configuration file \"~ts\", "
              "incorrect format: ~p",
              [AdvancedConfigFile, OtherTerms]),
            throw({error, failed_to_parse_advanced_configuration_file});
        {error, Reason} ->
            rabbit_log_prelaunch:error(
              "Failed to load advanced configuration file \"~ts\": ~ts",
              [AdvancedConfigFile, file:format_error(Reason)]),
            throw({error, failed_to_read_advanced_configuration_file})
    end.

apply_erlang_term_based_config([{App, Vars} | Rest]) ->
    rabbit_log_prelaunch:debug(
      "Applying configuration for '~s': ~p",
      [App, Vars]),
    apply_app_env_vars(App, Vars),
    apply_erlang_term_based_config(Rest);
apply_erlang_term_based_config([]) ->
    ok.

apply_app_env_vars(App, [{Var, Value} | Rest]) ->
    ok = application:set_env(App, Var, Value, [{persistent, true}]),
    apply_app_env_vars(App, Rest);
apply_app_env_vars(_, []) ->
    ok.

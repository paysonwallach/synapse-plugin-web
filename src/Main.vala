/*
 * Copyright (c) 2020 Payson Wallach
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

namespace Synapse {
    [DBus (name = "com.paysonwallach.attention")]
    private interface WindowManagerBuseIFace : Object {
        public abstract void activate_window_demanding_attention () throws DBusError, IOError;

    }

    private class WindowManagerProxy : Object {
        private static Once<WindowManagerProxy> instance;

        public static unowned WindowManagerProxy get_default () {
            return instance.once (() => {
                return new WindowManagerProxy ();
            });
        }

        construct {
            try {
            } catch (IOError err) {
                warning (err.message);
            }
        }

        public void activate_window_demanding_attention () {
            try {
                WindowManagerBuseIFace? window_manager = Bus.get_proxy_sync (
                    BusType.SESSION,
                    "com.paysonwallach.attention",
                    "/com/paysonwallach/attention");

                window_manager.activate_window_demanding_attention ();
            } catch (DBusError err) {
                error (@"DBusError: $(err.message)");
            } catch (IOError err) {
                error (@"IOError: $(err.message)");
            }
        }

    }

    [DBus (name = "com.paysonwallach.synapse.plugins.web.bridge")]
    private interface WebBridgeBusIFace : Object {
        public abstract void open_url (string url) throws DBusError, IOError;

    }

    private class WebBridgeProxy : Object {
        private uint watch_id = 0U;

        private static Once<WebBridgeProxy> instance;

        public static unowned WebBridgeProxy get_default () {
            return instance.once (() => {
                return new WebBridgeProxy ();
            });
        }

        public void open_url (string url) {
            try {
                request_proxy_open (url);
            } catch (DBusError err) {
                if (err.code == DBusError.SERVICE_UNKNOWN) {
                    request_browser_launch (url);
                } else {
                    warning (@"DBusError: $(err.message)");
                }
            } catch (IOError err) {
                warning (@"IOError: $(err.message)");
            }
        }

        private void request_proxy_open (string url) throws DBusError, IOError {
            WebBridgeBusIFace? proxy = Bus.get_proxy_sync (
                BusType.SESSION,
                "com.paysonwallach.synapse.plugins.web.bridge",
                "/com/paysonwallach/synapse/plugins/web/bridge");

            proxy.open_url (url);
        }

        private void request_browser_launch (string url) {
            var app_info = AppInfo.get_default_for_type ("text/html", false);
            if (app_info == null)
                return;

            try {
                app_info.launch_uris (null, null);
                watch_id = Bus.watch_name (
                    BusType.SESSION,
                    "com.paysonwallach.amber.bridge", BusNameWatcherFlags.NONE,
                    () => on_name_acquired (url));
            } catch (Error err) {
                warning (@"unable to get default type: $(err.message)");
            }
        }

        private void on_name_acquired (string url) {
            try {
                request_proxy_open (url);
            } catch (Error err) {
                warning (@"error: $(err.message)");
            }

            if (watch_id != 0U)
                Bus.unwatch_name (watch_id);
        }

    }

    private class SynapseWebMatch : ActionMatch {
        public string url { get; construct set; }

        public SynapseWebMatch (string name, string? description, string url) {
            Object (
                title: name,
                description: description != null ? description : url,
                url: url,
                has_thumbnail: false,
                icon_name: "firefox");
        }

        public override void do_action () {
            WebBridgeProxy.get_default ().open_url (url);
            WindowManagerProxy.get_default ().activate_window_demanding_attention ();
        }

    }

    public class WebPlugin : Object, Activatable, ItemProvider {
        private RelevancyService relevancy_service;
        private Zeitgeist.Index zeitgeist_index;

        public const string UNIQUE_NAME = "org.gnome.zeitgeist.Engine";
        public bool enabled { get; set; default = true; }

        private static GenericArray<Zeitgeist.Event> get_template () {
            var template = new GenericArray<Zeitgeist.Event> ();
            var event = new Zeitgeist.Event ();

            event.interpretation = "http://www.zeitgeist-project.com/ontologies/2010/01/27/zg#AccessEvent";
            event.manifestation = "http://www.zeitgeist-project.com/ontologies/2010/01/27/zg#UserActivity";
            event.actor = "application://firefox.desktop";

            template.add (event);

            return template;
        }

        public void activate () {
            relevancy_service = RelevancyService.get_default ();
            zeitgeist_index = new Zeitgeist.Index ();
        }

        public void deactivate () {}

        public bool handles_query (Query query) {
            return (QueryFlags.ACTIONS in query.query_type);
        }

        private bool search_in_progress = false;
        public async ResultSet? search (Query query) throws SearchError {
            if (query.query_string.length < 2)
                return null;

            var search_query = query.query_string.strip ();
            var results = new ResultSet ();

            while (search_in_progress) {
                ulong sig_id;
                sig_id = this.notify["search-in-progress"].connect (() => {
                    if (search_in_progress)
                        return;
                    search.callback ();
                });
                yield;

                SignalHandler.disconnect (this, sig_id);
                query.check_cancellable ();
            }

            try {
                string[] words = Regex.split_simple ("\\s+|\\.+(?!\\d)", search_query);
                search_query = "(%s*)".printf (string.joinv ("* ", words));

                debug (@"searching for $search_query...");
                var zeitgeist_results = yield zeitgeist_index.search (search_query,
                                                                      new Zeitgeist.TimeRange (int64.MIN, int64.MAX),
                                                                      get_template (),
                                                                      0,
                                                                      query.max_results,
                                                                      Zeitgeist.ResultType.MOST_RECENT_SUBJECTS,
                                                                      null);

                debug (@"number of results found: $(zeitgeist_results.estimated_matches ())");
                foreach (var event in zeitgeist_results) {
                    query.check_cancellable ();

                    if (event.num_subjects () <= 0)
                        continue;

                    var subject = event.get_subject (0);

                    if (subject.text == null)
                        continue;

                    if (subject.uri.split ("://")[0] == "file")
                        continue;

                    results.add (
                        new SynapseWebMatch (subject.text, null, subject.uri),
                        RelevancyService.compute_relevancy (
                            MatchScore.AVERAGE,
                            relevancy_service.get_uri_popularity (subject.uri)));
                }
            } catch (Error error) {
                if (!query.is_cancelled ())
                    warning (@"Zeitgeist search failed: $(error.message)");
            }

            search_in_progress = false;

            query.check_cancellable ();

            return results;
        }
    }
}

public Synapse.PluginInfo register_plugin () {
    Synapse.PluginInfo plugin_info = null;
    var dbus_service = Synapse.DBusService.get_default ();
    var icon_name = "applications-internet";
    var loop = new MainLoop ();

    dbus_service.name_is_activatable_async.begin (
            Synapse.WebPlugin.UNIQUE_NAME, (obj, res) => {
        var activatable = dbus_service.name_is_activatable_async.end (res);
        var default_browser = AppInfo.get_default_for_type ("text/html", true);

        if (default_browser != null)
            icon_name = default_browser.get_icon ().to_string ();

        plugin_info = new Synapse.PluginInfo (
            typeof (Synapse.WebPlugin),
            "Web",
            "Search web browser history.",
            icon_name,
            null,
            activatable,
            "Zeitgeist is not installed");

        loop.quit ();
    });
    loop.run ();

    return plugin_info;
}

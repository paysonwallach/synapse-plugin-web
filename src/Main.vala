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
    public class WebPlugin : Object, Activatable, ItemProvider {
        [DBus (name = "com.paysonwallach.synapse.plugins.web.bridge")]
        public interface WebBridgeBusIFace : Object {
            public abstract int query (string body, out UnixInputStream stream) throws DBusError, IOError;
            public abstract void open_url (string url) throws DBusError, IOError;

        }

        public class WebBridgeProxy : Object {
            private WebBridgeBusIFace? bus = null;

            public signal void results_ready (UnixInputStream stream);

            private static Once<WebBridgeProxy> instance;

            public static unowned WebBridgeProxy get_default () {
                return instance.once (() => {
                    return new WebBridgeProxy ();
                });
            }

            construct {
                try {
                    bus = Bus.get_proxy_sync (
                        BusType.SESSION,
                        "com.paysonwallach.synapse.plugins.web.bridge",
                        "/com/paysonwallach/synapse_firefox/connector"
                        );
                } catch (IOError err) {
                    warning (err.message);
                }
            }

            public int query (string body, out UnixInputStream stream) {
                var result = -1;

                try {
                    result = bus.query (body, out stream);
                } catch (DBusError err) {
                    warning (@"DBusError: $(err.message)");
                } catch (IOError err) {
                    warning (@"IOError: $(err.message)");
                }

                return result;
            }

            public void open_url (string url) {
                try {
                    bus.open_url (url);
                } catch (DBusError err) {
                    error (@"DBusError: $(err.message)");
                } catch (IOError err) {
                    error (@"IOError: $(err.message)");
                }
            }

        }

        private struct Page {
            public string name;
            public string? description;
            public string url;

            public Page (string name, string? description, string url) {
                this.name = name;
                this.description = description;
                this.url = url;
            }

        }

        private class PageMatch : ActionMatch {
            public string url { get; construct set; }

            public PageMatch (string name, string? description, string url) {
                Object (
                    title: name,
                    description: description != null ? description : url,
                    has_thumbnail: false,
                    icon_name: "firefox",
                    url: url);
            }

            public override void do_action () {
                WebBridgeProxy.get_default ().open_url (url);

                Wnck.Screen? screen = Wnck.Screen.get_default ();

                screen.force_update ();
                screen.get_windows ().@foreach ((window) => {
                    if (window.get_state () == Wnck.WindowState.DEMANDS_ATTENTION)
                        window.activate_transient (Gdk.x11_get_server_time (Gdk.get_default_root_window ()));
                });
            }

        }

        public bool enabled { get; set; default = true; }

        public void activate () {}

        public void deactivate () {}

        public bool handles_query (Query query) {
            return (QueryFlags.ACTIONS in query.query_type);
        }

        public async ResultSet? search (Query query) throws SearchError {
            var result_set = new ResultSet ();

            if (query.query_string.length < 2)
                return result_set;

            UnixInputStream input_stream;

            WebBridgeProxy.get_default ().query (query.query_string, out input_stream);

            var results_count = -1;

            do {
                Bytes results_count_message_length_bytes = null;

                try {
                    results_count_message_length_bytes = yield input_stream.read_bytes_async (4);
                } catch (Error err) {
                    warning (@"unable to read results count: $(err.message)");
                }

                var results_count_message_length = get_message_content_length (results_count_message_length_bytes);

                debug (@"$results_count_message_length");

                if (results_count_message_length == 0)
                    continue;

                Bytes results_count_message_bytes = null;

                try {
                    results_count_message_bytes = yield input_stream.read_bytes_async (results_count_message_length);
                } catch (Error err) {
                    warning (@"Error: $(err.message)");
                }

                results_count = int.parse ((string) results_count_message_bytes.get_data ());
            } while (results_count == -1);

            var parser = new Json.Parser ();

            for (int i = 0 ; i < results_count ; i++) {
                Bytes message_bytes = null;
                Bytes message_length_bytes = null;

                try {
                    message_length_bytes = yield input_stream.read_bytes_async (4);
                } catch (Error err) {
                    warning (@"Error: $(err.message)");
                }

                if (message_length_bytes.get_size () == 0)
                    continue;

                var message_content_length = get_message_content_length (message_length_bytes);

                if (message_content_length == 0)
                    continue;

                try {
                    message_bytes = yield input_stream.read_bytes_async (message_content_length);
                } catch (Error err) {
                    warning (@"Error: $(err.message)");
                }

                try {
                    parser.load_from_data (
                        (string) message_bytes.get_data (),
                        (ssize_t) message_bytes.get_size ());
                } catch (Error err) {
                    warning (err.message);
                }

                unowned Json.Node node = parser.get_root ();

                if (node.get_node_type () != Json.NodeType.OBJECT) {
                    warning (@"message root is of type $(node.type_name ())");
                } else {
                    unowned Json.Object object = node.get_object ();
                    var title = object.get_string_member ("title");
                    var url = object.get_string_member ("url");

                    result_set.add (
                        new PageMatch (title, null, url),
                        (int) MatchScore.AVERAGE * ((results_count - i) / results_count));
                }

                query.check_cancellable ();
            }

            return result_set;
        }

        private size_t get_message_content_length (Bytes message_length_bytes) {
            size_t message_content_length = 0;
            uint8[] message_length_buffer = message_length_bytes.get_data ();

            if (message_length_bytes.get_size () == 4)
                message_content_length = (
                    (message_length_buffer[3] << 24)
                    + (message_length_buffer[2] << 16)
                    + (message_length_buffer[1] << 8)
                    + (message_length_buffer[0])
                    );

            return message_content_length;
        }

    }
}

Synapse.PluginInfo register_plugin () {
    return new Synapse.PluginInfo (
        typeof (Synapse.WebPlugin),
        "Firefox",
        "Search your bookmarks and browser history.",
        "firefox",
        null,
        Environment.find_program_in_path ("firefox") != null,
        "Firefox is not installed."
        );
}

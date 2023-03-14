#! /usr/bin/python

import gi
import sys
import signal

gi.require_version('Gtk', '3.0')
gi.require_version('WebKit2', '4.0')

from gi.repository import Gtk, GObject, WebKit2

VIDEO_MIME_TYPES = [
  'application/vnd.apple.mpegurl',
  'application/x-mpegURL'
]

class Parser(Gtk.Box):

  __gtype_name__ = 'Parser'
  __gsignals__   = { 'success': (GObject.SignalFlags.RUN_FIRST, None, (object,)) }

  def __init__(self, *args, **kwargs):
    Gtk.Box.__init__(self, *args, **kwargs)

    self.context = WebKit2.WebContext.new_ephemeral()
    self.webview = WebKit2.WebView.new_with_context(self.context)
    self.webdata = self.webview.get_website_data_manager()

    self.webview.connect('resource-load-started', self.on_load_resource)
    self.webview.set_is_muted(True)
    self.webdata.set_tls_errors_policy(WebKit2.TLSErrorsPolicy.IGNORE)

    self.pack_start(self.webview, True, True, 0)

  def load_uri(self, uri):
    self.webview.load_uri(uri)

  def on_load_resource(self, _widget, resource, _request):
    resource.connect('notify::response', self.on_notify_response)

  def on_notify_response(self, resource, _response):
    if resource.get_response().get_mime_type() in VIDEO_MIME_TYPES:
      self.emit('success', resource.get_uri())


class Crawler:

  def __init__(self):
    self.window = Gtk.Window()
    self.window.connect('destroy', self.on_window_destroy)

    self.window.set_title('Crawler')
    self.window.set_icon_name('mpv')
    self.window.set_default_size(1024, 576)

    self.parser = Parser()
    self.parser.connect('success', self.on_parser_success)

    self.widget = Gtk.Box()
    self.widget.pack_start(self.parser, True, True, 0)

    self.window.add(self.widget)

  def run(self, url):
    self.window.show_all()
    self.parser.load_uri(url)

    Gtk.main()

  def quit(self):
    Gtk.main_quit()

  def on_parser_success(self, _parser, stream_uri):
    print(stream_uri)
    self.quit()

  def on_window_destroy(self, _event):
    self.quit()


if __name__ == '__main__':
  signal.signal(signal.SIGINT, signal.SIG_DFL)

  crawler = Crawler()
  crawler.run(sys.argv[1])

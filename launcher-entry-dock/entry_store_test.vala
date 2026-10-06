using LauncherEntryDock;

Variant props(int64 count, bool visible) {
    var b = new VariantBuilder(new VariantType("a{sv}"));
    b.add("{sv}", "count", new Variant.int64(count));
    b.add("{sv}", "count-visible", new Variant.boolean(visible));
    return b.end();
}

void test_merge_and_hide() {
    var store = new EntryStore();
    store.update("application://dev.sinty.Store.desktop", ":1.5", props(3, true));
    assert(store.entries.has_key("dev.sinty.store"));
    assert(store.entries["dev.sinty.store"].desktop_id == "dev.sinty.Store");
    assert(store.entries["dev.sinty.store"].count == 3);
    store.update("application://dev.sinty.Store.desktop", ":1.5", props(0, false));
    assert(!store.entries.has_key("dev.sinty.store"));
}

void test_vanish_rules() {
    var store = new EntryStore();
    store.update("application://dev.sinty.news.desktop", ":1.7", props(4, true));
    store.entries["dev.sinty.news"].app_owned = true;
    store.update("application://dev.sinty.store.desktop", ":1.8", props(2, true));
    assert(store.sender_vanished(":1.7"));
    assert(!store.entries.has_key("dev.sinty.news"));
    assert(!store.sender_vanished(":1.8"));
    assert(store.entries.has_key("dev.sinty.store"));
}

void test_new_sender_resets_ownership() {
    var store = new EntryStore();
    store.update("application://dev.sinty.news.desktop", ":1.7", props(4, true));
    store.entries["dev.sinty.news"].app_owned = true;
    store.update("application://dev.sinty.news.desktop", ":1.9", props(5, true));
    assert(!store.entries["dev.sinty.news"].app_owned);
    assert(!store.sender_vanished(":1.7"));
}

void test_round_trip() {
    var store = new EntryStore();
    store.update("application://dev.sinty.Store.desktop", ":1.8", props(2, true));
    var progress = new VariantBuilder(new VariantType("a{sv}"));
    progress.add("{sv}", "progress", new Variant.double(0.5));
    progress.add("{sv}", "progress-visible", new Variant.boolean(true));
    progress.add("{sv}", "label", new Variant.string("disk.iso"));
    store.update("application://dev.sinty.drivewriter.desktop", ":1.9", progress.end());
    store.entries["dev.sinty.drivewriter"].app_owned = true;
    var copy = new EntryStore();
    copy.load_data(store.to_data());
    assert(copy.entries.size == 2);
    var s = copy.entries["dev.sinty.store"];
    assert(s.count == 2 && s.count_visible && !s.app_owned && s.sender == ":1.8" && s.desktop_id == "dev.sinty.Store");
    var d = copy.entries["dev.sinty.drivewriter"];
    assert(d.progress == 0.5 && d.progress_visible && d.app_owned && d.label == "disk.iso");
    copy.load_data("not a key file [");
    assert(copy.entries.size == 2);
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/launcher-entry/merge-and-hide", test_merge_and_hide);
    Test.add_func("/launcher-entry/vanish-rules", test_vanish_rules);
    Test.add_func("/launcher-entry/new-sender", test_new_sender_resets_ownership);
    Test.add_func("/launcher-entry/round-trip", test_round_trip);
    return Test.run();
}

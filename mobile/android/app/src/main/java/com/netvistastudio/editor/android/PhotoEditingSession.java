package com.netvistastudio.editor.android;

import java.io.IOException;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/** One-owner native photo commands and immutable snapshots. The UI retains layer
 * identities, not list indices. A preview renderer may safely capture state().
 */
public final class PhotoEditingSession {
    public interface LayerEdit { PhotoDocument.Layer edit(PhotoDocument.Layer value) throws IOException; }
    private static final class History {
        final PhotoDocument document; final String label;
        History(PhotoDocument document, String label) { this.document = document; this.label = label; }
    }
    private PhotoDocument state;
    private final ArrayDeque<History> undo = new ArrayDeque<>(), redo = new ArrayDeque<>();
    private History transaction;
    private final int maximumHistorySteps;
    private final long historyByteBudget;
    private long revision;
    private String lastAction = "New document";

    public PhotoEditingSession(PhotoDocument state) { this(state, 80, 256_000_000L); }
    public PhotoEditingSession(PhotoDocument state, int maximumHistorySteps, long historyByteBudget) {
        if (state == null) throw new IllegalArgumentException("Photo document is missing.");
        this.state = state; this.maximumHistorySteps = Math.max(1, Math.min(200, maximumHistorySteps)); this.historyByteBudget = Math.max(1, historyByteBudget);
    }
    public PhotoDocument state() { return state; }
    public long revision() { return revision; }
    public String lastAction() { return lastAction; }
    public boolean isEditing() { return transaction != null; }
    public boolean canUndo() { return !undo.isEmpty() || transaction != null && !state.same(transaction.document); }
    public boolean canRedo() { return transaction == null && !redo.isEmpty(); }
    public int undoCount() { return undo.size(); }
    public int redoCount() { return redo.size(); }
    public PhotoDocument.Layer selectedLayer() { return state.layer(state.selectedLayerId); }

    /** Decode and validate before touching the current document, transaction or history. */
    public void load(String json) throws IOException {
        PhotoDocument candidate = PhotoDocument.decode(json);
        state = candidate; transaction = null; undo.clear(); redo.clear(); lastAction = "Open project"; revision++;
    }
    public String encodedProject() throws IOException { return state.encode(); }
    public void newDocument(PhotoDocument candidate) throws IOException {
        if (candidate == null) throw new IOException("Photo document is missing."); finishTransaction(); publish(candidate, "New document");
    }
    public void select(String id) throws IOException {
        PhotoDocument candidate = state.selecting(id); finishTransaction();
        if (!state.same(candidate)) { state = candidate; revision++; }
    }
    public void beginTransaction(String label) throws IOException {
        if (transaction != null) throw new IOException("Finish the current photo gesture first.");
        transaction = new History(state, label == null || label.isEmpty() ? "Photo edit" : label);
    }
    public void finishTransaction() {
        if (transaction == null) return;
        History before = transaction; transaction = null;
        if (!state.same(before.document)) { undo.addLast(before); redo.clear(); lastAction = before.label; trimHistory(); }
    }
    public void cancelTransaction() { if (transaction != null) { state = transaction.document; transaction = null; revision++; } }
    public boolean undo() {
        finishTransaction(); if (undo.isEmpty()) return false;
        History before = undo.removeLast(); redo.addLast(new History(state, before.label)); state = before.document; lastAction = "Undo · " + before.label; revision++; trimRedo(); return true;
    }
    public boolean redo() {
        if (transaction != null || redo.isEmpty()) return false;
        History next = redo.removeLast(); undo.addLast(new History(state, next.label)); state = next.document; lastAction = "Redo · " + next.label; revision++; trimHistory(); return true;
    }
    public boolean isEditable(String id) {
        PhotoDocument.Layer layer = state.layer(id); if (layer == null || layer.locked) return false;
        PhotoDocument.Layer parent = state.layer(layer.groupId); return parent == null || !parent.locked;
    }
    public void mutateLayer(String id, String label, LayerEdit edit) throws IOException {
        PhotoDocument.Layer original = editable(id), next = edit.edit(original);
        if (next == null || !PhotoDocument.idKey(original.id).equals(PhotoDocument.idKey(next.id)) || original.group != next.group || !sameId(original.groupId, next.groupId))
            throw new IOException("Use folder commands to change layer identity or grouping.");
        replace(original, next, label);
    }
    public void rename(String id, String name) throws IOException { mutateLayer(id, "Rename layer", layer -> layer.withProperty("name", name)); }
    public void opacity(String id, double value) throws IOException { mutateLayer(id, "Layer opacity", layer -> layer.withProperty("opacity", value)); }
    public void blendMode(String id, String value) throws IOException { mutateLayer(id, "Blend mode", layer -> layer.withProperty("blendMode", value)); }
    public void position(String id, double x, double y) throws IOException { mutateLayer(id, "Move layer", layer -> layer.withProperty("positionX", x).withProperty("positionY", y)); }
    public void pixels(String id, PhotoDocument.Pixels value) throws IOException { mutateLayer(id, "Paint layer", layer -> layer.withPixels(value)); }
    public void mask(String id, PhotoDocument.Pixels value) throws IOException { mutateLayer(id, "Layer mask", layer -> layer.withMask(value)); }
    public void adjustment(String id, String key, double value) throws IOException { mutateLayer(id, "Photo adjustment", layer -> layer.withAdjustment(key, value)); }
    public void visible(String id, boolean value) throws IOException { metadata(id, "Layer visibility", "isVisible", value); }
    public void locked(String id, boolean value) throws IOException { metadata(id, "Layer lock", "isLocked", value); }
    private void metadata(String id, String label, String key, boolean value) throws IOException {
        PhotoDocument.Layer layer = state.layer(id); if (layer == null) throw new IOException("This photo layer no longer exists."); replace(layer, layer.withProperty(key, value), label);
    }
    private PhotoDocument.Layer editable(String id) throws IOException { if (!isEditable(id)) throw new IOException("Unlock the layer and its folder before editing."); return state.layer(id); }
    private void replace(PhotoDocument.Layer before, PhotoDocument.Layer after, String label) throws IOException {
        List<PhotoDocument.Layer> layers = new ArrayList<>(state.layers); layers.set(layers.indexOf(before), after); publish(state.withLayers(layers, state.selectedLayerId), label);
    }
    public String add(PhotoDocument.Layer layer) throws IOException {
        if (layer == null || layer.group || layer.groupId != null || state.layer(layer.id) != null) throw new IOException("Choose a new ungrouped image layer.");
        PhotoDocument.Layer selected = selectedLayer(); String parent = selected == null ? null : selected.group ? selected.id : selected.groupId;
        if (parent != null) editable(parent);
        PhotoDocument.Layer next = layer.inGroup(parent); List<PhotoDocument.Layer> layers = new ArrayList<>(state.layers);
        int index = selected == null ? 0 : layers.indexOf(selected) + (selected.group ? 1 : 0); layers.add(index, next);
        PhotoDocument candidate = state.withLayers(layers, next.id); finishTransaction(); publish(candidate, "Add layer"); return next.id;
    }
    public void remove(String id) throws IOException {
        PhotoDocument.Layer item = editable(id); List<PhotoDocument.Layer> layers = new ArrayList<>(state.layers);
        layers.removeIf(layer -> layer == item || id.equalsIgnoreCase(layer.groupId));
        PhotoDocument candidate = state.withLayers(layers, state.selectedLayerId); finishTransaction(); publish(candidate, "Delete layer");
    }
    public String duplicate(String id) throws IOException {
        PhotoDocument.Layer item = state.layer(id); if (item == null) throw new IOException("Select a photo layer to duplicate.");
        String nextId = UUID.randomUUID().toString(); List<PhotoDocument.Layer> block = new ArrayList<>(); block.add(item.duplicate(nextId, item.groupId));
        if (item.group) for (PhotoDocument.Layer child : state.layers) if (id.equalsIgnoreCase(child.groupId)) block.add(child.duplicate(UUID.randomUUID().toString(), nextId));
        List<PhotoDocument.Layer> layers = new ArrayList<>(state.layers); layers.addAll(layers.indexOf(item), block);
        PhotoDocument candidate = state.withLayers(layers, nextId); finishTransaction(); publish(candidate, "Duplicate layer"); return nextId;
    }
    public void reorder(String id, int offset) throws IOException {
        PhotoDocument.Layer item = editable(id); List<PhotoDocument.Layer> siblings = new ArrayList<>();
        for (PhotoDocument.Layer layer : state.layers) if (sameId(layer.groupId, item.groupId)) siblings.add(layer);
        int old = siblings.indexOf(item), target = (int) Math.max(0L, Math.min(siblings.size() - 1L, old + (long) offset));
        if (old == target) { finishTransaction(); return; }
        PhotoDocument.Layer anchor = siblings.get(target); List<PhotoDocument.Layer> block = new ArrayList<>(), remaining = new ArrayList<>();
        for (PhotoDocument.Layer layer : state.layers) { if (layer == item || id.equalsIgnoreCase(layer.groupId)) block.add(layer); else remaining.add(layer); }
        int insertion = remaining.indexOf(anchor);
        if (target > old) { insertion++; while (insertion < remaining.size() && anchor.id.equalsIgnoreCase(remaining.get(insertion).groupId)) insertion++; }
        remaining.addAll(insertion, block); PhotoDocument candidate = state.withLayers(remaining, state.selectedLayerId); finishTransaction(); publish(candidate, "Reorder layers");
    }
    public String group(List<String> ids, String name, PhotoDocument.Pixels folderPixel) throws IOException {
        if (ids == null || ids.isEmpty()) throw new IOException("Select image layers to group.");
        Set<String> keys = new HashSet<>(); for (String id : ids) { PhotoDocument.Layer layer = editable(id); if (layer.group || !keys.add(PhotoDocument.idKey(id))) throw new IOException("Select distinct image layers; nested folders are unsupported."); }
        PhotoDocument.Layer folder = PhotoDocument.folder(name, folderPixel); List<PhotoDocument.Layer> layers = new ArrayList<>(), children = new ArrayList<>(); int insertion = -1;
        for (PhotoDocument.Layer layer : state.layers) { if (keys.contains(PhotoDocument.idKey(layer.id))) { if (insertion < 0) insertion = layers.size(); children.add(layer.inGroup(folder.id)); } else layers.add(layer); }
        layers.add(insertion, folder); layers.addAll(insertion + 1, children);
        PhotoDocument candidate = state.withLayers(layers, folder.id); finishTransaction(); publish(candidate, "Group layers"); return folder.id;
    }
    public void ungroup(String id) throws IOException {
        PhotoDocument.Layer folder = editable(id); if (!folder.group) throw new IOException("Select a layer folder to ungroup.");
        List<PhotoDocument.Layer> layers = new ArrayList<>();
        for (PhotoDocument.Layer layer : state.layers) if (layer != folder) layers.add(id.equalsIgnoreCase(layer.groupId) ? layer.inGroup(null) : layer);
        PhotoDocument candidate = state.withLayers(layers, layers.isEmpty() ? null : layers.get(0).id); finishTransaction(); publish(candidate, "Ungroup layers");
    }
    private void publish(PhotoDocument candidate, String label) {
        if (state.same(candidate)) return;
        if (transaction == null) { undo.addLast(new History(state, label)); redo.clear(); }
        state = candidate; lastAction = label; revision++; if (transaction == null) trimHistory();
    }
    private static boolean sameId(String first, String second) { return first == null ? second == null : second != null && first.equalsIgnoreCase(second); }
    /** Metadata snapshots share compressed pixels; budget only distinct old allocations. */
    private long historyCost(Iterable<History> history) {
        Set<PhotoDocument.Pixels> seen = Collections.newSetFromMap(new IdentityHashMap<>());
        remember(state, seen); long total = 0;
        for (History entry : history) for (PhotoDocument.Layer layer : entry.document.layers) {
            if (seen.add(layer.pixels)) total += layer.pixels.byteCount();
            if (layer.mask != null && seen.add(layer.mask)) total += layer.mask.byteCount();
        }
        return total;
    }
    private static void remember(PhotoDocument document, Set<PhotoDocument.Pixels> seen) { for (PhotoDocument.Layer layer : document.layers) { seen.add(layer.pixels); if (layer.mask != null) seen.add(layer.mask); } }
    private void trimHistory() { while (undo.size() > maximumHistorySteps) undo.removeFirst(); while (undo.size() > 1 && historyCost(undo) > historyByteBudget) undo.removeFirst(); }
    private void trimRedo() { while (redo.size() > maximumHistorySteps) redo.removeFirst(); while (redo.size() > 1 && historyCost(redo) > historyByteBudget) redo.removeFirst(); }
}

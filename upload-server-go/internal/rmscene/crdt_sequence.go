package rmscene

import "container/heap"

type nodeKey struct {
	sentinel uint8 // 0 normal, 1 __start, 2 __end
	id       CrdtID
}

func startNode() nodeKey       { return nodeKey{sentinel: 1} }
func endNode() nodeKey         { return nodeKey{sentinel: 2} }
func idNode(id CrdtID) nodeKey { return nodeKey{sentinel: 0, id: id} }

type sortKey [3]int64

// heap-friendly sort key: __start < normal < __end.
// Within normal: higher Part1 first (matching Python's -part1), then Part2 ascending.
func keyFor(n nodeKey) sortKey {
	switch n.sentinel {
	case 1:
		return sortKey{0, 0, 0}
	case 2:
		return sortKey{2, 0, 0}
	default:
		return sortKey{1, -int64(n.id.Part1), int64(n.id.Part2)}
	}
}

type heapItem struct {
	key  sortKey
	node nodeKey
}

type minHeap []heapItem

func (h minHeap) Len() int { return len(h) }
func (h minHeap) Less(i, j int) bool {
	for k := 0; k < 3; k++ {
		if h[i].key[k] != h[j].key[k] {
			return h[i].key[k] < h[j].key[k]
		}
	}
	return false
}
func (h minHeap) Swap(i, j int) { h[i], h[j] = h[j], h[i] }
func (h *minHeap) Push(x any)   { *h = append(*h, x.(heapItem)) }
func (h *minHeap) Pop() any {
	old := *h
	n := len(old)
	x := old[n-1]
	*h = old[:n-1]
	return x
}

// toposort returns ItemIDs in CRDT order.
func toposort(items []TextItem) []CrdtID {
	if len(items) == 0 {
		return nil
	}
	itemDict := make(map[CrdtID]struct{}, len(items))
	for _, it := range items {
		itemDict[it.ItemID] = struct{}{}
	}

	resolve := func(side CrdtID, isLeft bool) nodeKey {
		if side == endMarker {
			if isLeft {
				return startNode()
			}
			return endNode()
		}
		if _, ok := itemDict[side]; !ok {
			if isLeft {
				return startNode()
			}
			return endNode()
		}
		return idNode(side)
	}

	inDeg := map[nodeKey]int{}
	deps := map[nodeKey][]nodeKey{}
	all := map[nodeKey]struct{}{
		startNode(): {},
		endNode():   {},
	}
	for _, it := range items {
		itK := idNode(it.ItemID)
		l := resolve(it.LeftID, true)
		ri := resolve(it.RightID, false)
		all[itK] = struct{}{}
		all[l] = struct{}{}
		all[ri] = struct{}{}
		inDeg[itK]++
		deps[l] = append(deps[l], itK)
		inDeg[ri]++
		deps[itK] = append(deps[itK], ri)
	}
	for n := range all {
		if _, ok := inDeg[n]; !ok {
			inDeg[n] = 0
		}
	}

	h := &minHeap{}
	heap.Init(h)
	for n := range all {
		if inDeg[n] == 0 {
			heap.Push(h, heapItem{key: keyFor(n), node: n})
		}
	}

	out := make([]CrdtID, 0, len(items))
	for h.Len() > 0 {
		top := heap.Pop(h).(heapItem)
		node := top.node
		if node.sentinel == 0 {
			if _, ok := itemDict[node.id]; ok {
				out = append(out, node.id)
			}
		}
		if node.sentinel == 2 {
			break
		}
		for _, d := range deps[node] {
			inDeg[d]--
			if inDeg[d] == 0 {
				heap.Push(h, heapItem{key: keyFor(d), node: d})
			}
		}
	}
	return out
}

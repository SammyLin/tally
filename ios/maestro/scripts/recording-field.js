// output.value = field FIELD of the first recording matching Q (trash=1 when TRASH is set); for assertTrue.
const list = json(http.get(BACKEND + '/api/recordings?q=' + encodeURIComponent(Q) + (typeof TRASH !== 'undefined' ? '&trash=1' : '')).body)
output.value = list.length ? String(list[0][FIELD]) : 'none'

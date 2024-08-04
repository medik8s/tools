package backend

import (
	"encoding/json"
	"io/fs"
	"log"
	"net/http"
	"strconv"
)

func Start(frontend fs.FS, serverAddress string, version string) error {

	mux := http.NewServeMux()

	// serve the frontend on root
	webapp := http.FileServer(http.FS(frontend))
	mux.Handle("/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Println("handling root request, forwarding to embedded file server")
		webapp.ServeHTTP(w, r)
	}))

	// serve data
	mux.Handle("/version", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Println("handling /version request")
		w.Header().Set("Content-Type", "text/plain")
		_, err := w.Write([]byte(version))
		if err != nil {
			log.Println(err)
		}
	}))

	// serve data
	mux.Handle("/data", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Println("handling /data request")
		reload := false
		if reloadParam := r.URL.Query().Get("reload"); reloadParam != "" {
			val, err := strconv.ParseBool(reloadParam)
			reload = err == nil && val
			log.Printf("reload: %s\n", strconv.FormatBool(reload))
		}
		indexImages, err := GetIndexImages(reload)
		if err != nil {
			log.Println(err)
			return
		}

		log.Printf("going to return %v results", len(indexImages))
		data, err := json.Marshal(indexImages)
		w.Header().Set("Content-Type", "application/json")
		_, err = w.Write(data)
		if err != nil {
			log.Println(err)
		}
	}))

	srv := &http.Server{
		Handler: mux,
		Addr:    serverAddress,
	}
	return srv.ListenAndServe()
}

package api

import "time"

type Result struct {
	Operator      string    `json:"operator"`
	BundleImage   string    `json:"bundleImage"`
	BundleRelease string    `json:"bundleRelease"`
	BundleVersion string    `json:"bundleVersion"`
	OcpVersion    string    `json:"ocpVersion"`
	IndexImage    string    `json:"indexImage"`
	IndexNumber   string    `json:"indexNumber"`
	GeneratedAt   time.Time `json:"generatedAt"`
}

type Messages struct {
	Arguments struct {
		Categories    []interface{} `json:"categories"`
		Contains      []string      `json:"contains"`
		Delta         float64       `json:"delta"`
		End           float64       `json:"end"`
		Grouped       bool          `json:"grouped"`
		Meta          []interface{} `json:"meta"`
		NotCategories []interface{} `json:"not_categories"`
		NotPackages   []interface{} `json:"not_packages"`
		NotTopics     []interface{} `json:"not_topics"`
		NotUsers      []interface{} `json:"not_users"`
		Order         string        `json:"order"`
		Packages      []interface{} `json:"packages"`
		Page          int           `json:"page"`
		RowsPerPage   int           `json:"rows_per_page"`
		Start         float64       `json:"start"`
		Topics        []string      `json:"topics"`
		Users         []interface{} `json:"users"`
	} `json:"arguments"`
	Count       int `json:"count"`
	Pages       int `json:"pages"`
	RawMessages []struct {
		Certificate interface{} `json:"certificate"`
		Crypto      interface{} `json:"crypto"`
		Headers     struct {
			CINAME                     string `json:"CI_NAME"`
			CITYPE                     string `json:"CI_TYPE"`
			JMSXUserID                 string `json:"JMSXUserID"`
			Amq6100Destination         string `json:"amq6100_destination"`
			Amq6100OriginalDestination string `json:"amq6100_originalDestination"`
			Category                   string `json:"category"`
			CorrelationId              string `json:"correlation-id"`
			Destination                string `json:"destination"`
			Expires                    string `json:"expires"`
			MessageId                  string `json:"message-id"`
			OriginalDestination        string `json:"original-destination"`
			Persistent                 string `json:"persistent"`
			Priority                   string `json:"priority"`
			Source                     string `json:"source"`
			Subscription               string `json:"subscription"`
			Timestamp                  string `json:"timestamp"`
			Topic                      string `json:"topic"`
			Type                       string `json:"type"`
			Version                    string `json:"version"`
		} `json:"headers"`
		I   int `json:"i"`
		Msg struct {
			Artifact struct {
				AdvisoryId      string `json:"advisory_id"`
				BrewBuildTag    string `json:"brew_build_tag"`
				BrewBuildTarget string `json:"brew_build_target"`
				Component       string `json:"component"`
				FullName        string `json:"full_name"`
				Id              string `json:"id"`
				ImageTag        string `json:"image_tag"`
				Issuer          string `json:"issuer"`
				Name            string `json:"name"`
				Namespace       string `json:"namespace"`
				Nvr             string `json:"nvr"`
				RegistryUrl     string `json:"registry_url"`
				Scratch         string `json:"scratch"`
				Type            string `json:"type"`
			} `json:"artifact"`
			Ci struct {
				Doc   string `json:"doc"`
				Email string `json:"email"`
				Name  string `json:"name"`
				Team  string `json:"team"`
				Url   string `json:"url"`
			} `json:"ci"`
			GeneratedAt time.Time `json:"generated_at"`
			Index       struct {
				AddedBundleImages []string `json:"added_bundle_images"`
				IndexImage        string   `json:"index_image"`
				OcpVersion        string   `json:"ocp_version"`
			} `json:"index"`
			Pipeline struct {
				Build           string `json:"build"`
				CpaasPipelineId string `json:"cpaas_pipeline_id"`
				Id              string `json:"id"`
				Name            string `json:"name"`
				Status          string `json:"status"`
			} `json:"pipeline"`
			Run struct {
				Log string `json:"log"`
				Url string `json:"url"`
			} `json:"run"`
			Timestamp time.Time `json:"timestamp"`
			Version   string    `json:"version"`
		} `json:"msg"`
		MsgId         string      `json:"msg_id"`
		Signature     interface{} `json:"signature"`
		SourceName    string      `json:"source_name"`
		SourceVersion string      `json:"source_version"`
		Timestamp     float64     `json:"timestamp"`
		Topic         string      `json:"topic"`
		Username      interface{} `json:"username"`
	} `json:"raw_messages"`
	Total int `json:"total"`
}

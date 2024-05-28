package main

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"
)

func main() {

	topic := "/topic/VirtualTopic.eng.ci.redhat-container-image.index.built"
	searchTerm := "workload-availability"
	timeFrame := 4 * 7 * 24 * time.Hour // 4 weeks
	rowsPerPage := 100                  // 100 is max allowed value!

	// keys are ocp version, operator name and operator version
	results := make(map[string]map[string]map[string]Result)

	tr := &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	}
	client := &http.Client{Transport: tr}

	for page := 1; true; page++ {
		url := fmt.Sprintf("https://datagrepper.engineering.redhat.com/raw?topic=%s&delta=%v&contains=%s&rows_per_page=%v&page=%v", topic, int(timeFrame.Seconds()), searchTerm, rowsPerPage, page)
		//fmt.Printf("URL: %s\n\n", url)
		//fmt.Println("getting more results, please wait...")

		req, err := http.NewRequest("GET", url, nil)
		if err != nil {
			fmt.Println(err)
			os.Exit(1)
		}

		resp, err := client.Do(req)
		if err != nil {
			fmt.Println(err)
			os.Exit(1)
		}
		defer resp.Body.Close()

		responseBytes, err := io.ReadAll(resp.Body)
		if err != nil {
			fmt.Println(err)
			os.Exit(1)
		}

		if resp.StatusCode != 200 {
			fmt.Printf("HTTP status code: %d\n", resp.StatusCode)
			fmt.Printf("Response: %s\n", string(responseBytes))
			os.Exit(1)
		}

		messages := &Messages{}
		err = json.Unmarshal(responseBytes, messages)
		if err != nil {
			fmt.Println(err)
			os.Exit(1)
		}

		if len(messages.RawMessages) == 0 {
			fmt.Println("no builds found!")
			return
		}

		for i := 0; i < len(messages.RawMessages); i++ {
			message := messages.RawMessages[i].Msg
			ocpVersion := message.Index.OcpVersion
			nvr := message.Artifact.Nvr
			operator, release, version := getOperatorReleaseVersionFromNvr(nvr)
			if _, exists := results[ocpVersion]; exists {
				if _, exists := results[ocpVersion][operator]; exists {
					if _, exists := results[ocpVersion][operator][version]; exists {
						continue
					}
				}
			}
			generatedAt := message.GeneratedAt
			bundleImage := message.Index.AddedBundleImages[0]
			indexImage := message.Index.IndexImage
			indexNr := getNrFromIndexImage(indexImage)
			if _, exists := results[ocpVersion]; !exists {
				results[ocpVersion] = make(map[string]map[string]Result)
			}
			if _, exists := results[ocpVersion][operator]; !exists {
				results[ocpVersion][operator] = make(map[string]Result)
			}
			results[ocpVersion][operator][version] = Result{
				Operator:      operator,
				BundleVersion: version,
				BundleRelease: release,
				BundleImage:   bundleImage,
				OcpVersion:    ocpVersion,
				IndexImage:    indexImage,
				IndexNumber:   indexNr,
				GeneratedAt:   generatedAt,
			}
		}

		if messages.Pages == page {
			break
		}

	}

	printResults(results)
}

func getOperatorReleaseVersionFromNvr(nvr string) (string, string, string) {
	match := "-bundle-container-"
	index := strings.Index(nvr, match)
	if index == -1 {
		fmt.Printf("could not find operator and version in NVR: %s\n", nvr)
		return nvr, "n/a", "n/a"
	}
	operator := nvr[:index]
	release := nvr[index+len(match):]
	version := strings.Split(release, "-")[0]
	return operator, release, version
}

func getNrFromIndexImage(indexImage string) string {
	match := "/iib:"
	index := strings.Index(indexImage, match)
	if index == -1 {
		fmt.Printf("could not find index number in index image: %s\n", indexImage)
		return indexImage
	}
	return indexImage[index+len(match):]
}

func printResults(results map[string]map[string]map[string]Result) {
	// sort by OCP version
	ocpVersions := make([]string, 0, len(results))
	for ocpVersion := range results {
		ocpVersions = append(ocpVersions, ocpVersion)
	}
	sort.Strings(ocpVersions)
	sortedResults := make([]Result, 0)
	for _, ocpVersion := range ocpVersions {
		//fmt.Printf("OCP Version: %s\n", ocpVersion)
		//fmt.Println("==================")
		ocpVersionResults := results[ocpVersion]
		operators := make([]string, 0, len(ocpVersionResults))
		for operator := range ocpVersionResults {
			operators = append(operators, operator)
		}
		sort.Strings(operators)
		for _, operator := range operators {
			operatorResults := ocpVersionResults[operator]
			for version := range operatorResults {
				result := operatorResults[version]
				sortedResults = append(sortedResults, result)
				//fmt.Printf("%s release %s in index %s, added on %s\n", result.operator, result.bundleRelease, result.indexNumber, result.generatedAt.Format(time.RFC1123))
			}
			//fmt.Println("---")
		}
	}
	resultBytes, err := json.MarshalIndent(sortedResults, "", "  ")
	if err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	fmt.Println(string(resultBytes))
}

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

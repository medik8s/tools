package backend

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"golang.org/x/mod/semver"

	"github.com/medik8s/findIndexImage/api"
)

var (
	cachedResults []api.Result
	lock          sync.Mutex
)

func GetIndexImages(reload bool) ([]api.Result, error) {

	lock.Lock()
	defer lock.Unlock()

	if cachedResults != nil &&
		len(cachedResults) > 0 &&
		!reload {

		log.Println("using cached results")
		return cachedResults, nil
	}

	topic := "/topic/VirtualTopic.eng.ci.redhat-container-image.index.built"
	searchTerm := "workload-availability"
	timeFrame := 4 * 7 * 24 * time.Hour // 4 weeks
	rowsPerPage := 100                  // 100 is max allowed value!

	// keys are ocp version, operator name and operator version
	var results []api.Result

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
			return nil, err
		}

		resp, err := client.Do(req)
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()

		responseBytes, err := io.ReadAll(resp.Body)
		if err != nil {
			return nil, err
		}

		if resp.StatusCode != 200 {
			fmt.Printf("HTTP status code: %d\n", resp.StatusCode)
			fmt.Printf("Response: %s\n", string(responseBytes))
			return nil, api.ErrorServer{Msg: fmt.Sprintf("server error: http status code: %v, response %v", resp.StatusCode, string(responseBytes))}
		}

		messages := &api.Messages{}
		err = json.Unmarshal(responseBytes, messages)
		if err != nil {
			return nil, err
		}

		if len(messages.RawMessages) == 0 {
			return nil, api.ErrorNotFound{}
		}

		rawMessages := messages.RawMessages
		// sort by release and not build date, in case a newer build was finished faster than an older one
		sort.Slice(rawMessages, func(i, j int) bool {
			getIdentifier := func(nvr string) string {
				operator, version, release := getOperatorVersionReleaseFromNvr(nvr)
				return fmt.Sprintf("%s-%s-%s", operator, version, release)
			}
			return getIdentifier(rawMessages[i].Msg.Artifact.Nvr) < getIdentifier(rawMessages[j].Msg.Artifact.Nvr)
		})

		for i := 0; i < len(rawMessages); i++ {
			message := messages.RawMessages[i].Msg
			ocpVersion := message.Index.OcpVersion
			nvr := message.Artifact.Nvr
			operator, version, release := getOperatorVersionReleaseFromNvr(nvr)
			// return latest build only
			for _, result := range results {
				if result.OcpVersion == ocpVersion &&
					result.Operator == operator &&
					result.BundleVersion == version {
					continue
				}
			}
			generatedAt := message.GeneratedAt
			bundleImage := message.Index.AddedBundleImages[0]
			indexImage := message.Index.IndexImage
			indexNr := getNrFromIndexImage(indexImage)
			result := api.Result{
				Operator:      operator,
				BundleVersion: version,
				BundleRelease: release,
				BundleImage:   bundleImage,
				OcpVersion:    ocpVersion,
				IndexImage:    indexImage,
				IndexNumber:   indexNr,
				GeneratedAt:   generatedAt,
			}
			results = append(results, result)
		}

		if messages.Pages == page {
			break
		}

	}

	// sort by OCP version, operator, release
	sort.Slice(results, func(i, j int) bool {
		a := results[i]
		b := results[j]
		if a.OcpVersion != b.OcpVersion {
			return a.OcpVersion > b.OcpVersion
		}
		if a.Operator != b.Operator {
			return a.Operator < b.Operator
		}
		return semver.Compare(a.BundleRelease, b.BundleRelease) == 1
	})

	cachedResults = results
	return results, nil
}

func getOperatorVersionReleaseFromNvr(nvr string) (string, string, string) {
	match := "-bundle-container-"
	index := strings.Index(nvr, match)
	if index == -1 {
		fmt.Printf("could not find operator and version in NVR: %s\n", nvr)
		return nvr, "n/a", "n/a"
	}
	operator := nvr[:index]
	release := nvr[index+len(match):]
	version := strings.Split(release, "-")[0]
	return operator, version, release
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

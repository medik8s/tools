//go:build js

package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"syscall/js"
	"time"

	"honnef.co/go/js/dom/v2"

	"github.com/medik8s/findIndexImage/api"
)

type Page struct {
	versionDiv    *dom.HTMLDivElement
	refreshButton *dom.HTMLButtonElement
	msgDiv        *dom.HTMLDivElement
	tableHead     *dom.HTMLTableSectionElement
	tableBody     *dom.HTMLTableSectionElement
	newListFunc   js.Value
}

func main() {

	el := dom.GetWindow().Document().GetElementByID("version")
	versionDiv := el.(*dom.HTMLDivElement)

	el = dom.GetWindow().Document().GetElementByID("refresh")
	refreshButton := el.(*dom.HTMLButtonElement)

	el = dom.GetWindow().Document().GetElementByID("msg")
	msgDiv := el.(*dom.HTMLDivElement)

	el = dom.GetWindow().Document().GetElementByID("results-head")
	tableHead := el.(*dom.HTMLTableSectionElement)

	el = dom.GetWindow().Document().GetElementByID("results-body")
	tableBody := el.(*dom.HTMLTableSectionElement)

	newListFunc := js.Global().Get("newList")

	page := &Page{
		versionDiv:    versionDiv,
		refreshButton: refreshButton,
		msgDiv:        msgDiv,
		tableHead:     tableHead,
		tableBody:     tableBody,
		newListFunc:   newListFunc,
	}

	page.registerCallbacks()
	page.getVersion()
	page.getData(false)

	// don't exit
	select {}
}

func (p *Page) registerCallbacks() {
	p.refreshButton.AddEventListener("click", false, p.refreshClick)
}

func (p *Page) refreshClick(_ dom.Event) {
	// must be async here! See description here: https://pkg.go.dev/syscall/js#FuncOf
	go p.getData(true)
}

func (p *Page) getVersion() {
	resp, err := http.Get("version")
	if err != nil {
		msg := fmt.Sprintf("failed to get version: %v", err)
		println(msg)
		p.msgDiv.SetInnerHTML(msg)
		return
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		msg := fmt.Sprintf("failed to read data: %v", err)
		println(msg)
		p.msgDiv.SetInnerHTML(msg)
		return
	}
	p.versionDiv.SetInnerHTML(string(body))
}

func (p *Page) getData(reload bool) {
	println("getting data")
	go p.msgDiv.SetInnerHTML("Getting index images. VPN required! Please wait...")

	resp, err := http.Get(fmt.Sprintf("data?reload=%s", strconv.FormatBool(reload)))
	if err != nil {
		msg := fmt.Sprintf("failed to get data: %v", err)
		println(msg)
		p.msgDiv.SetInnerHTML(msg)
		return
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		msg := fmt.Sprintf("failed to read data: %v", err)
		println(msg)
		p.msgDiv.SetInnerHTML(msg)
		return
	}
	results := []api.Result{}
	err = json.Unmarshal(body, &results)
	if err != nil {
		msg := fmt.Sprintf("failed to parse data: %v", err)
		println(msg)
		p.msgDiv.SetInnerHTML(msg)
		return
	}

	go p.msgDiv.SetInnerHTML(fmt.Sprintf("Got %v index images.", len(results)))

	p.fillTable(results)
}

func (p *Page) fillTable(results []api.Result) {
	println("printing data")

	headers := []string{"OCP version", "Operator", "Release", "Index Image", "Created at"}
	trimHeader := func(s string) string {
		s = strings.ToLower(s)
		s = strings.ReplaceAll(s, " ", "")
		return s
	}
	tableHead := "<tr>"
	tableOptions := make([]any, 0)
	for _, header := range []string{"OCP version", "Operator", "Release", "Index Image", "Created at"} {
		tableHead += fmt.Sprintf("<th>%v</th>\n", header)
		tableOptions = append(tableOptions, trimHeader(header))
	}
	tableHead += "</tr>\n"
	p.tableHead.SetInnerHTML(tableHead)

	tableRows := ""
	for _, r := range results {
		tableRows += "<tr>"
		for col, data := range []string{r.OcpVersion, r.Operator, r.BundleRelease, r.IndexImage, r.GeneratedAt.Format(time.RFC3339)} {
			tableRows += fmt.Sprintf("<td class=%q>%v</td>\n", trimHeader(headers[col]), data)
		}
		tableRows += "</tr>\n"
	}
	p.tableBody.SetInnerHTML(tableRows)

	// init list.js
	p.newListFunc.Invoke(tableOptions)
}

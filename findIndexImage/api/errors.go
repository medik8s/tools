package api

type ErrorNotFound struct{}

func (e ErrorNotFound) Error() string {
	return "not found"
}

type ErrorServer struct {
	Msg string
}

func (e ErrorServer) Error() string {
	return e.Msg
}

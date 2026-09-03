import { Link } from "react-router-dom";
import Button from "../../components/Button";

export default function SignUp () {
    return (
        <>
            <div>
                Sign Up Page
            </div>
            <div>
                <span>Welcome Back</span>                
                <div>
                    <label htmlFor="email">Email</label>
                    <input type="email" />
                </div>
                <div>
                    <label htmlFor="password">Password</label>
                    <input type="password" />
                </div>
                <Button
                    message='Sign Up'
                />
                <Link to="/login">Forgot Password?</Link>
            </div>
        </>
    )
}